import Foundation

internal actor CDPConnection {
  private enum Lifecycle { case idle, connecting, connected, closing, closed, failed }
  private enum SendPhase { case sending, sent }
  private struct Pending {
    var phase: SendPhase
    let method: String
    let sessionID: String?
    let continuation: CheckedContinuation<JSONValue, Error>
    var timeoutTask: Task<Void, Never>?
  }

  private let transport: any WebSocketTransport
  private let maximumMessageBytes: Int
  private var lifecycle: Lifecycle = .idle
  private var nextID = 1
  private var pending: [Int: Pending] = [:]
  private var pageSessionID: String?
  private var receiveTask: Task<Void, Never>?
  private var termination: ObscuraError?
  private var terminationWaiters: [UUID: CheckedContinuation<ObscuraError?, Never>] = [:]

  init(transport: any WebSocketTransport, maximumMessageBytes: Int) {
    self.transport = transport
    self.maximumMessageBytes = maximumMessageBytes
  }

  func connect() async throws {
    guard lifecycle == .idle else {
      throw ObscuraError.invalidState("CDP connect requires idle state")
    }
    lifecycle = .connecting
    do {
      try await transport.connect()
      guard lifecycle == .connecting else { throw ObscuraError.closed }
      lifecycle = .connected
      receiveTask = Task { [weak self] in await self?.receiveLoop() }
    } catch let error as ObscuraError {
      await fail(error)
      throw error
    } catch {
      let mapped = ObscuraError.transport("CDP connect failed: \(error)")
      await fail(mapped)
      throw mapped
    }
  }

  func call(
    _ method: String,
    params: JSONValue = .object([:]),
    sessionID: String? = nil,
    timeout: Duration
  ) async throws -> JSONValue {
    guard timeout > .zero else {
      throw ObscuraError.invalidConfiguration("CDP timeout must be positive")
    }
    guard !method.isEmpty, method.utf8.count <= 512, !method.contains("\0") else {
      throw ObscuraError.invalidConfiguration("CDP method is invalid")
    }
    try validateSessionID(sessionID)
    guard lifecycle == .connected else {
      if lifecycle == .closed || lifecycle == .closing { throw ObscuraError.closed }
      throw termination ?? .transport("CDP connection is unavailable")
    }
    guard nextID < Int.max else {
      let error = ObscuraError.resourceLimit("CDP request identifier exhausted")
      await fail(error)
      throw error
    }
    let id = nextID
    nextID += 1
    let frame = try VendoredObscuraWireEncoder.encode(
      CDPRequest(id: id, method: method, params: params, sessionID: sessionID),
      maximumBytes: maximumMessageBytes
    )

    return try await registerAndSend(
      id: id, method: method, sessionID: sessionID, frame: frame, timeout: timeout)
  }

  func adoptPageSession(_ sessionID: String) throws {
    guard lifecycle == .connected else {
      throw termination ?? ObscuraError.closed
    }
    try validateSessionID(sessionID)
    guard pageSessionID == nil else {
      throw ObscuraError.invalidState("CDP page session is already established")
    }
    pageSessionID = sessionID
  }

  func callPage(
    _ method: String,
    params: JSONValue = .object([:]),
    timeout: Duration
  ) async throws -> JSONValue {
    guard let pageSessionID else {
      throw ObscuraError.invalidState("CDP page session is not established")
    }
    return try await call(method, params: params, sessionID: pageSessionID, timeout: timeout)
  }

  func waitForTermination() async -> ObscuraError? {
    if lifecycle == .closed || lifecycle == .failed { return termination }
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if lifecycle == .closed || lifecycle == .failed {
          continuation.resume(returning: termination)
        } else {
          terminationWaiters[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelTerminationWaiter(id) }
    }
  }

  func close() async {
    guard lifecycle != .closed else { return }
    lifecycle = .closing
    receiveTask?.cancel()
    receiveTask = nil
    await transport.close()
    finishPending(with: .closed)
    lifecycle = .closed
    finishTerminationWaiters()
  }

  private func registerAndSend(
    id: Int,
    method: String,
    sessionID: String?,
    frame: String,
    timeout: Duration
  ) async throws -> JSONValue {
    try await withTaskCancellationHandler {
      if Task.isCancelled { throw ObscuraError.cancelled(method) }
      return try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<JSONValue, Error>) in
        guard lifecycle == .connected else {
          continuation.resume(throwing: termination ?? ObscuraError.closed)
          return
        }
        pending[id] = Pending(
          phase: .sending,
          method: method,
          sessionID: sessionID,
          continuation: continuation,
          timeoutTask: nil
        )
        let timeoutTask = Task { [weak self] in
          do {
            try await Task.sleep(for: timeout)
          } catch {
            return
          }
          await self?.cancelRequest(id: id, error: .operationTimedOut(method))
        }
        pending[id]?.timeoutTask = timeoutTask
        Task { await self.sendPending(id: id, frame: frame) }
      }
    } onCancel: {
      Task { await self.cancelRequest(id: id, error: .cancelled(method)) }
    }
  }

  private func sendPending(id: Int, frame: String) async {
    guard pending[id] != nil, lifecycle == .connected else { return }
    do {
      try await transport.send(text: frame)
      guard var current = pending[id] else { return }
      current.phase = .sent
      pending[id] = current
    } catch let error as ObscuraError {
      await fail(error)
    } catch {
      await fail(.transport("CDP send failed: \(error)"))
    }
  }

  private func receiveLoop() async {
    while !Task.isCancelled {
      do {
        let text = try await transport.receive()
        try await handleInbound(text)
      } catch is CancellationError {
        if lifecycle == .connected {
          await fail(.transport("CDP receive loop was cancelled unexpectedly"))
        }
        return
      } catch let error as ObscuraError {
        if lifecycle == .connected {
          if case .resourceLimit(let message) = error {
            await fail(.protocolViolation(message))
          } else {
            await fail(error)
          }
        }
        return
      } catch {
        if lifecycle == .connected { await fail(.transport("CDP receive failed: \(error)")) }
        return
      }
    }
  }

  private func handleInbound(_ text: String) async throws {
    guard text.utf8.count <= maximumMessageBytes else {
      throw ObscuraError.resourceLimit("inbound CDP frame exceeds configured limit")
    }
    let message: CDPInbound
    do {
      message = try JSONDecoder().decode(CDPInbound.self, from: Data(text.utf8))
    } catch {
      throw ObscuraError.protocolViolation("malformed CDP JSON: \(error)")
    }
    if let id = message.id {
      guard id > 0 else {
        throw ObscuraError.protocolViolation("CDP response identifier must be positive")
      }
      guard message.method == nil, message.params == nil else {
        throw ObscuraError.protocolViolation("CDP response also contains event fields")
      }
      guard (message.result == nil) != (message.error == nil) else {
        throw ObscuraError.protocolViolation(
          "CDP response must contain exactly one of result or error")
      }
      guard let request = pending[id] else {
        throw ObscuraError.protocolViolation("response for unknown request id \(id)")
      }
      guard message.sessionId == request.sessionID else {
        throw ObscuraError.protocolViolation("CDP response session does not match its request")
      }
      pending.removeValue(forKey: id)
      request.timeoutTask?.cancel()
      if let error = message.error {
        request.continuation.resume(
          throwing: ObscuraError.cdp(code: error.code, message: error.message))
      } else {
        request.continuation.resume(returning: message.result ?? .null)
      }
      return
    }

    guard let method = message.method,
      !method.isEmpty,
      method.utf8.count <= 512,
      !method.contains("\0"),
      message.result == nil,
      message.error == nil
    else {
      throw ObscuraError.protocolViolation("CDP message is neither a valid response nor event")
    }
    if let sessionID = message.sessionId, sessionID != pageSessionID {
      throw ObscuraError.protocolViolation("CDP event belongs to an unexpected session")
    }
    if let params = message.params, case .object = params {
      // Valid event parameters. The minimal public product contract does not
      // expose raw CDP events, so well-formed events are intentionally dropped.
    } else if message.params != nil {
      throw ObscuraError.protocolViolation("CDP event params must be an object when present")
    }
  }

  private func cancelRequest(id: Int, error: ObscuraError) async {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.timeoutTask?.cancel()
    request.continuation.resume(throwing: error)
    await fail(error)
  }

  private func fail(_ error: ObscuraError) async {
    guard lifecycle != .closed, lifecycle != .failed else { return }
    termination = error
    lifecycle = .failed
    receiveTask?.cancel()
    receiveTask = nil
    await transport.close()
    finishPending(with: error)
    finishTerminationWaiters()
  }

  private func finishPending(with error: ObscuraError) {
    let values = pending.values
    pending.removeAll(keepingCapacity: false)
    for request in values {
      request.timeoutTask?.cancel()
      request.continuation.resume(throwing: error)
    }
  }

  private func finishTerminationWaiters() {
    let waiters = terminationWaiters.values
    terminationWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume(returning: termination) }
  }

  private func cancelTerminationWaiter(_ id: UUID) {
    guard let waiter = terminationWaiters.removeValue(forKey: id) else { return }
    waiter.resume(returning: .cancelled("termination wait"))
  }

  private func validateSessionID(_ sessionID: String?) throws {
    guard let sessionID else { return }
    guard !sessionID.isEmpty, sessionID.utf8.count <= 512, !sessionID.contains("\0") else {
      throw ObscuraError.invalidConfiguration("CDP session identifier is invalid")
    }
  }
}
