import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

internal actor FoundationWebSocketTransport: WebSocketTransport {
  private enum State { case idle, connected, closed }

  private let endpoint: URL
  private let maximumMessageBytes: Int
  private var state: State = .idle
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?

  init(endpoint: URL, maximumMessageBytes: Int) throws {
    guard endpoint.scheme == "ws",
      endpoint.host == "127.0.0.1",
      endpoint.path == "/devtools/browser"
        || (endpoint.path.hasPrefix("/devtools/browser/")
          && endpoint.path.count > "/devtools/browser/".count),
      endpoint.port != nil,
      endpoint.user == nil,
      endpoint.password == nil,
      endpoint.query == nil,
      endpoint.fragment == nil
    else {
      throw ObscuraError.transport("WebSocket endpoint is outside the browser loopback boundary")
    }
    self.endpoint = endpoint
    self.maximumMessageBytes = maximumMessageBytes
  }

  internal static func makeSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    // A session is intentionally long-lived. Per-operation deadlines belong to
    // CDPConnection; a URLSession resource deadline would terminate an otherwise
    // healthy WebSocket independently of the state machine.
    configuration.timeoutIntervalForResource = TimeInterval.greatestFiniteMagnitude
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.connectionProxyDictionary = [:]
    return configuration
  }

  func connect() async throws {
    guard state == .idle else {
      throw ObscuraError.transport("WebSocket connect called outside idle state")
    }
    let session = URLSession(configuration: Self.makeSessionConfiguration())
    let task = session.webSocketTask(with: endpoint)
    self.session = session
    self.task = task
    task.resume()
    // URLSessionWebSocketTask does not expose a portable handshake callback.
    // In particular, FoundationNetworking's sendPing may fail before the
    // upgrade has completed. The first protocol send/receive is therefore
    // the authoritative connection check and propagates the real error.
    state = .connected
  }

  func send(text: String) async throws {
    guard state == .connected, let task else {
      throw ObscuraError.transport("WebSocket is not connected")
    }
    guard text.utf8.count <= maximumMessageBytes else {
      throw ObscuraError.resourceLimit("outbound WebSocket message exceeds limit")
    }
    do {
      try await task.send(.string(text))
    } catch {
      throw ObscuraError.transport("WebSocket send failed: \(error)")
    }
  }

  func receive() async throws -> String {
    guard state == .connected, let task else {
      throw ObscuraError.transport("WebSocket is not connected")
    }
    do {
      let message = try await task.receive()
      switch message {
      case .string(let text):
        guard text.utf8.count <= maximumMessageBytes else {
          throw ObscuraError.resourceLimit("inbound WebSocket message exceeds limit")
        }
        return text
      case .data(let data):
        guard data.count <= maximumMessageBytes else {
          throw ObscuraError.resourceLimit("inbound WebSocket message exceeds limit")
        }
        guard let text = String(data: data, encoding: .utf8) else {
          throw ObscuraError.protocolViolation("binary WebSocket message is not UTF-8 JSON")
        }
        return text
      @unknown default:
        throw ObscuraError.protocolViolation("unknown WebSocket message kind")
      }
    } catch let error as ObscuraError {
      throw error
    } catch {
      throw ObscuraError.transport("WebSocket receive failed: \(error)")
    }
  }

  func close() async {
    guard state != .closed else { return }
    state = .closed
    task?.cancel(with: .normalClosure, reason: nil)
    session?.invalidateAndCancel()
    task = nil
    session = nil
  }
}
