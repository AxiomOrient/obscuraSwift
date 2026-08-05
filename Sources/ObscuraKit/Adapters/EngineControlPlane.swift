import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

internal struct EngineEndpoint: Sendable, Equatable {
  let browserWebSocketURL: URL
  let pageTargetID: String
  let browserVersion: String
  let protocolVersion: String
  let engineFlavor: EngineFlavor

  init(
    browserWebSocketURL: URL,
    pageTargetID: String,
    browserVersion: String,
    protocolVersion: String,
    engineFlavor: EngineFlavor = .obscura
  ) {
    self.browserWebSocketURL = browserWebSocketURL
    self.pageTargetID = pageTargetID
    self.browserVersion = browserVersion
    self.protocolVersion = protocolVersion
    self.engineFlavor = engineFlavor
  }
}

internal protocol EngineControlPlane: Sendable {
  func discover(
    port: UInt16,
    flavor: EngineFlavor,
    timeout: Duration
  ) async throws -> EngineEndpoint
}

extension EngineControlPlane {
  func discover(port: UInt16, timeout: Duration) async throws -> EngineEndpoint {
    try await discover(port: port, flavor: .obscura, timeout: timeout)
  }
}

internal struct LoopbackEngineControlPlane: EngineControlPlane {
  private let maximumResponseBytes: Int

  init(maximumResponseBytes: Int = 1_048_576) {
    self.maximumResponseBytes = maximumResponseBytes
  }

  func discover(
    port: UInt16,
    flavor: EngineFlavor,
    timeout: Duration
  ) async throws -> EngineEndpoint {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var lastConnectError: Int32 = ECONNREFUSED

    while clock.now < deadline {
      do {
        let versionData = try await request(path: "/json/version", port: port, deadline: deadline)
        let listData = try await request(path: "/json", port: port, deadline: deadline)
        let protocolData = try await request(
          path: "/json/protocol",
          port: port,
          deadline: deadline,
          maximumResponseBytes: flavor == .chrome
            ? Swift.max(maximumResponseBytes, 4 * 1024 * 1024)
            : maximumResponseBytes
        )
        return try validate(
          versionData: versionData,
          listData: listData,
          protocolData: protocolData,
          port: port,
          flavor: flavor
        )
      } catch let error as HTTPProbeError {
        switch error {
        case .connect(let errno):
          lastConnectError = errno
          try await retryDelay(until: deadline)
        case .io(let errno) where errno == ECONNRESET || errno == EPIPE || errno == ETIMEDOUT:
          lastConnectError = errno
          try await retryDelay(until: deadline)
        case .deadline:
          lastConnectError = ETIMEDOUT
          try await retryDelay(until: deadline)
        default:
          throw ObscuraError.controlPlane(error.description)
        }
      }
    }
    throw ObscuraError.controlPlane(
      "engine did not become ready before deadline (last errno \(lastConnectError))")
  }

  private func retryDelay(until deadline: ContinuousClock.Instant) async throws {
    let remaining = ContinuousClock().now.duration(to: deadline)
    guard remaining > .zero else { return }
    try await Task.sleep(for: min(remaining, .milliseconds(25)))
  }

  private func request(
    path: String,
    port: UInt16,
    deadline: ContinuousClock.Instant,
    maximumResponseBytes: Int? = nil
  ) async throws -> Data {
    let remaining = ContinuousClock().now.duration(to: deadline)
    guard remaining > .zero else { throw HTTPProbeError.deadline }
    let timeoutMilliseconds = max(1, min(Int(remaining.wholeMilliseconds), 500))
    let responseLimit = maximumResponseBytes ?? self.maximumResponseBytes
    return try await Task.detached(priority: .utility) {
      try blockingHTTPRequest(
        path: path,
        port: port,
        timeoutMilliseconds: timeoutMilliseconds,
        maximumResponseBytes: responseLimit
      )
    }.value
  }

  private func validate(
    versionData: Data,
    listData: Data,
    protocolData: Data,
    port: UInt16,
    flavor: EngineFlavor
  ) throws -> EngineEndpoint {
    struct Version: Decodable {
      let browser: String
      let protocolVersion: String
      let webSocketDebuggerURL: String

      enum CodingKeys: String, CodingKey {
        case browser = "Browser"
        case protocolVersion = "Protocol-Version"
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
      }
    }
    struct Target: Decodable {
      let id: String
      let type: String
      let webSocketDebuggerURL: String

      enum CodingKeys: String, CodingKey {
        case id, type
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
      }
    }
    struct ProtocolDocument: Decodable {
      struct Version: Decodable {
        let major: String
        let minor: String
      }
      let version: Version
    }

    let decoder = JSONDecoder()
    let version: Version
    let targets: [Target]
    let protocolDocument: ProtocolDocument
    do {
      version = try decoder.decode(Version.self, from: versionData)
      targets = try decoder.decode([Target].self, from: listData)
      protocolDocument = try decoder.decode(ProtocolDocument.self, from: protocolData)
    } catch {
      throw ObscuraError.controlPlane("invalid discovery JSON: \(error)")
    }

    guard version.browser.hasPrefix("Chrome/") else {
      throw ObscuraError.controlPlane("unexpected Browser identity: \(version.browser)")
    }
    guard version.protocolVersion == "1.3",
      protocolDocument.version.major == "1",
      protocolDocument.version.minor == "3"
    else {
      throw ObscuraError.controlPlane("unsupported protocol version")
    }
    guard let browserURL = URL(string: version.webSocketDebuggerURL) else {
      throw ObscuraError.controlPlane("invalid browser WebSocket endpoint")
    }
    let page: Target
    switch flavor {
    case .obscura:
      guard version.webSocketDebuggerURL == "ws://127.0.0.1:\(port)/devtools/browser" else {
        throw ObscuraError.controlPlane("unexpected browser WebSocket endpoint")
      }
      guard let discovered = targets.first(where: { $0.id == "page-1" && $0.type == "page" }) else {
        throw ObscuraError.controlPlane("missing exact page-1 target")
      }
      guard discovered.webSocketDebuggerURL == "ws://127.0.0.1:\(port)/devtools/page/page-1" else {
        throw ObscuraError.controlPlane("unexpected page WebSocket endpoint")
      }
      page = discovered

    case .chrome:
      guard
        browserURL.scheme == "ws",
        browserURL.host == "127.0.0.1",
        browserURL.port == Int(port),
        browserURL.path.hasPrefix("/devtools/browser/"),
        browserURL.path.count > "/devtools/browser/".count
      else {
        throw ObscuraError.controlPlane("unexpected Chrome browser WebSocket endpoint")
      }
      guard
        let discovered = targets.first(where: { target in
          guard
            target.type == "page",
            let pageURL = URL(string: target.webSocketDebuggerURL)
          else {
            return false
          }
          return pageURL.scheme == "ws"
            && pageURL.host == "127.0.0.1"
            && pageURL.port == Int(port)
            && pageURL.path.hasPrefix("/devtools/page/")
            && pageURL.path.count > "/devtools/page/".count
        })
      else {
        throw ObscuraError.controlPlane("missing Chrome page target")
      }
      page = discovered
    }
    return EngineEndpoint(
      browserWebSocketURL: browserURL,
      pageTargetID: page.id,
      browserVersion: version.browser,
      protocolVersion: version.protocolVersion,
      engineFlavor: flavor
    )
  }
}

private enum HTTPProbeError: Error, CustomStringConvertible {
  case connect(Int32)
  case io(Int32)
  case deadline
  case oversized
  case malformed(String)

  var description: String {
    switch self {
    case .connect(let errno): "connect failed with errno \(errno)"
    case .io(let errno): "HTTP I/O failed with errno \(errno)"
    case .deadline: "HTTP request deadline elapsed"
    case .oversized: "HTTP response exceeded configured limit"
    case .malformed(let message): "malformed HTTP response: \(message)"
    }
  }
}

private func blockingHTTPRequest(
  path: String,
  port: UInt16,
  timeoutMilliseconds: Int,
  maximumResponseBytes: Int
) throws -> Data {
  #if canImport(Darwin)
    let socketType = SOCK_STREAM
    let microseconds = Int32((timeoutMilliseconds % 1_000) * 1_000)
  #else
    let socketType = Int32(SOCK_STREAM.rawValue)
    let microseconds = (timeoutMilliseconds % 1_000) * 1_000
  #endif
  let fd = socket(AF_INET, socketType, 0)
  guard fd >= 0 else { throw HTTPProbeError.io(errno) }
  defer { _ = close(fd) }

  var timeout = timeval(
    tv_sec: timeoutMilliseconds / 1_000,
    tv_usec: microseconds
  )
  let receiveTimeoutResult = withUnsafePointer(to: &timeout) { pointer in
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
  }
  guard receiveTimeoutResult == 0 else { throw HTTPProbeError.io(errno) }
  let sendTimeoutResult = withUnsafePointer(to: &timeout) { pointer in
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
  }
  guard sendTimeoutResult == 0 else { throw HTTPProbeError.io(errno) }

  #if canImport(Darwin)
    var noSignal: Int32 = 1
    let noSignalResult = withUnsafePointer(to: &noSignal) { pointer in
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
    }
    guard noSignalResult == 0 else { throw HTTPProbeError.io(errno) }
    let sendFlags: Int32 = 0
  #else
    let sendFlags = Int32(MSG_NOSIGNAL)
  #endif

  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = port.bigEndian
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  let connectResult = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard connectResult == 0 else { throw HTTPProbeError.connect(errno) }

  let request =
    "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAccept: */*\r\nConnection: close\r\n\r\n"
  let requestBytes = Array(request.utf8)
  var offset = 0
  while offset < requestBytes.count {
    let written = requestBytes.withUnsafeBytes { buffer in
      send(fd, buffer.baseAddress!.advanced(by: offset), requestBytes.count - offset, sendFlags)
    }
    if written > 0 {
      offset += written
    } else if written < 0, errno == EINTR {
      continue
    } else {
      throw HTTPProbeError.io(errno)
    }
  }

  var response = Data()
  var buffer = [UInt8](repeating: 0, count: 8_192)
  var expectedResponseBytes: Int?
  while true {
    let count = buffer.withUnsafeMutableBytes { bytes in
      recv(fd, bytes.baseAddress, bytes.count, 0)
    }
    if count > 0 {
      guard response.count + count <= maximumResponseBytes else { throw HTTPProbeError.oversized }
      response.append(contentsOf: buffer.prefix(count))
      if expectedResponseBytes == nil {
        expectedResponseBytes = try expectedHTTPResponseBytes(
          response,
          maximumResponseBytes: maximumResponseBytes
        )
      }
      if let expectedResponseBytes {
        guard response.count <= expectedResponseBytes else {
          throw HTTPProbeError.malformed("body length mismatch")
        }
        if response.count == expectedResponseBytes { break }
      }
    } else if count == 0 {
      break
    } else if errno == EINTR {
      continue
    } else if errno == EAGAIN || errno == EWOULDBLOCK {
      throw HTTPProbeError.deadline
    } else {
      throw HTTPProbeError.io(errno)
    }
  }

  guard let delimiter = response.range(of: Data("\r\n\r\n".utf8)) else {
    throw HTTPProbeError.malformed("missing header terminator")
  }
  let headerData = response[..<delimiter.lowerBound]
  let body = response[delimiter.upperBound...]
  guard let headerText = String(data: headerData, encoding: .utf8) else {
    throw HTTPProbeError.malformed("headers are not UTF-8")
  }
  let lines = headerText.components(separatedBy: "\r\n")
  guard lines.first == "HTTP/1.1 200 OK" else {
    throw HTTPProbeError.malformed("unexpected status line \(lines.first ?? "nil")")
  }
  var contentLength: Int?
  var contentType: String?
  var seenHeaders = Set<String>()
  for line in lines.dropFirst() {
    let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard pieces.count == 2 else { throw HTTPProbeError.malformed("invalid header") }
    let name = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
    let value = pieces[1].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { throw HTTPProbeError.malformed("empty header name") }
    if name == "content-length" || name == "content-type" || name == "transfer-encoding" {
      guard seenHeaders.insert(name).inserted else {
        throw HTTPProbeError.malformed("duplicate \(name) header")
      }
    }
    switch name {
    case "content-length":
      contentLength = try parseContentLength(value, maximumResponseBytes: maximumResponseBytes)
    case "content-type":
      contentType = value.lowercased()
    case "transfer-encoding":
      throw HTTPProbeError.malformed("Transfer-Encoding is not supported")
    default:
      break
    }
  }
  guard let contentType else {
    throw HTTPProbeError.malformed("missing or invalid Content-Type")
  }
  let mediaType =
    contentType
    .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
    .trimmingCharacters(in: .whitespaces)
  guard mediaType == "application/json" else {
    throw HTTPProbeError.malformed("missing or invalid Content-Type")
  }
  guard let contentLength else {
    throw HTTPProbeError.malformed("missing or invalid Content-Length")
  }
  guard body.count == contentLength else {
    throw HTTPProbeError.malformed("body length mismatch")
  }
  return Data(body)
}

private func expectedHTTPResponseBytes(
  _ response: Data,
  maximumResponseBytes: Int
) throws -> Int? {
  guard let delimiter = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
  let headerData = response[..<delimiter.lowerBound]
  guard let headerText = String(data: headerData, encoding: .utf8) else {
    throw HTTPProbeError.malformed("headers are not UTF-8")
  }
  let lines = headerText.components(separatedBy: "\r\n")
  guard lines.first == "HTTP/1.1 200 OK" else {
    throw HTTPProbeError.malformed("unexpected status line \(lines.first ?? "nil")")
  }
  var contentLength: Int?
  var seenContentLength = false
  for line in lines.dropFirst() {
    let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard pieces.count == 2 else { throw HTTPProbeError.malformed("invalid header") }
    let name = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
    let value = pieces[1].trimmingCharacters(in: .whitespaces)
    if name == "transfer-encoding" {
      throw HTTPProbeError.malformed("Transfer-Encoding is not supported")
    }
    if name == "content-length" {
      guard !seenContentLength else {
        throw HTTPProbeError.malformed("duplicate content-length header")
      }
      seenContentLength = true
      contentLength = try parseContentLength(value, maximumResponseBytes: maximumResponseBytes)
    }
  }
  guard let contentLength else {
    throw HTTPProbeError.malformed("missing or invalid Content-Length")
  }
  let total = delimiter.upperBound + contentLength
  guard total <= maximumResponseBytes else { throw HTTPProbeError.oversized }
  return total
}

private func parseContentLength(_ value: String, maximumResponseBytes: Int) throws -> Int {
  guard !value.isEmpty,
    value.utf8.allSatisfy({ (48...57).contains($0) }),
    let parsed = Int(value)
  else {
    throw HTTPProbeError.malformed("invalid Content-Length")
  }
  guard parsed <= maximumResponseBytes else { throw HTTPProbeError.oversized }
  return parsed
}
