import Foundation

@testable import ObscuraKit

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct TemporaryDirectory {
  let url: URL

  init(prefix: String = "ObscuraKitTests") throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    url = base
  }

  func remove() {
    try? FileManager.default.removeItem(at: url)
  }
}

func systemTrueExecutable() throws -> URL {
  for path in ["/usr/bin/true", "/bin/true"] {
    guard FileManager.default.isExecutableFile(atPath: path) else { continue }
    return URL(fileURLWithPath: path)
  }
  throw ObscuraError.executableNotFound("no system true executable was found")
}

struct FixtureExecutable {
  let temporaryDirectory: TemporaryDirectory
  let executable: URL
  let pidFile: URL
  let requestLog: URL

  static func make(mode: String = "normal", delaySeconds: Double = 2.0) throws -> FixtureExecutable
  {
    guard let fixture = Bundle.module.url(forResource: "fixture_engine", withExtension: "py") else {
      throw ObscuraError.invalidConfiguration("fixture_engine.py resource is missing")
    }
    let temporaryDirectory = try TemporaryDirectory(prefix: "ObscuraFixture")
    let executable = temporaryDirectory.url.appendingPathComponent("fixture-wrapper.sh")
    let pidFile = temporaryDirectory.url.appendingPathComponent("fixture.pid")
    let requestLog = temporaryDirectory.url.appendingPathComponent("requests.jsonl")
    let script = """
      #!/bin/sh
      set -eu
      export OBSCURA_FIXTURE_MODE=\(shellQuote(mode))
      export OBSCURA_FIXTURE_DELAY_SECONDS=\(shellQuote(String(delaySeconds)))
      export OBSCURA_FIXTURE_PID_FILE=\(shellQuote(pidFile.path))
      export OBSCURA_FIXTURE_REQUEST_LOG=\(shellQuote(requestLog.path))
      exec python3 \(shellQuote(fixture.path)) "$@"
      """
    try Data(script.utf8).write(to: executable, options: .atomic)
    guard chmod(executable.path, 0o700) == 0 else {
      throw ObscuraError.executableRejected("failed to mark fixture executable")
    }
    return FixtureExecutable(
      temporaryDirectory: temporaryDirectory,
      executable: executable,
      pidFile: pidFile,
      requestLog: requestLog
    )
  }

  func configuration(
    startupTimeout: Duration = .seconds(15),
    operationTimeout: Duration = .seconds(2),
    shutdownGrace: Duration = .milliseconds(100),
    maximumQueuedOperations: Int = 16
  ) throws -> LaunchConfiguration {
    try LaunchConfiguration(
      executable: .explicit(executable),
      startupTimeout: startupTimeout,
      operationTimeout: operationTimeout,
      shutdownGrace: shutdownGrace,
      diagnosticByteLimit: 16 * 1024,
      maximumMessageBytes: 1 * 1024 * 1024,
      maximumQueuedOperations: maximumQueuedOperations,
      allowPrivateNetwork: true
    )
  }

  func requestRecords() throws -> [[String: Any]] {
    guard FileManager.default.fileExists(atPath: requestLog.path) else { return [] }
    return try String(contentsOf: requestLog, encoding: .utf8)
      .split(separator: "\n")
      .map { line in
        guard let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else {
          throw ObscuraError.protocolViolation("fixture request log contains a non-object")
        }
        return value
      }
  }

  func recordedPID() -> Int32? {
    guard FileManager.default.fileExists(atPath: pidFile.path),
      let text = try? String(contentsOf: pidFile, encoding: .utf8),
      let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      return nil
    }
    return value
  }

  func forceTerminate() -> Bool {
    guard let pid = recordedPID() else { return false }
    return kill(pid, SIGKILL) == 0
  }

  func waitUntilStopped(timeout: Duration = .seconds(2)) async -> Bool {
    guard let pid = recordedPID() else { return true }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if kill(pid, 0) != 0, errno == ESRCH { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return kill(pid, 0) != 0 && errno == ESRCH
  }

  func forceCleanup() {
    if let pid = recordedPID(), kill(pid, 0) == 0 {
      _ = kill(-pid, SIGKILL)
      _ = kill(pid, SIGKILL)
    }
    temporaryDirectory.remove()
  }
}

private func shellQuote(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func dataURL(_ html: String) -> URL {
  let payload = Data(html.utf8).base64EncodedString()
  return URL(string: "data:text/html;base64,\(payload)")!
}

func eventually(
  timeout: Duration = .seconds(2),
  interval: Duration = .milliseconds(10),
  _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await predicate() { return true }
    try? await Task.sleep(for: interval)
  }
  return await predicate()
}

actor StopFailingProcess: EngineProcessHandle {
  private let base: EngineProcess

  init(base: EngineProcess) {
    self.base = base
  }

  func waitForExit() async throws -> EngineExit {
    try await base.waitForExit()
  }

  func isRunning() async -> Bool {
    await base.isRunning()
  }

  func diagnosticSnapshot() async -> String {
    await base.diagnosticSnapshot()
  }

  func stop() async throws -> EngineExit {
    throw ObscuraError.processLaunchFailed(errno: EIO, message: "synthetic stop failure")
  }

  nonisolated func terminateImmediately() {
    base.terminateImmediately()
  }
}

actor StopGate {
  private var entered = false
  private var released = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func waitForRelease() async {
    entered = true
    let waiters = enteredWaiters
    enteredWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
    if released { return }
    await withCheckedContinuation { continuation in
      if released {
        continuation.resume()
      } else {
        releaseWaiters.append(continuation)
      }
    }
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { continuation in
      if entered {
        continuation.resume()
      } else {
        enteredWaiters.append(continuation)
      }
    }
  }

  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }
}

actor GatedSendWebSocketTransport: WebSocketTransport {
  private let gate: StopGate
  private var connected = false
  private var closed = false
  private var sent: [String] = []
  private var receiveWaiter: CheckedContinuation<String, Error>?

  init(gate: StopGate) {
    self.gate = gate
  }

  func connect() async throws {
    guard !connected, !closed else { throw ObscuraError.invalidState("mock connect") }
    connected = true
  }

  func send(text: String) async throws {
    guard connected, !closed else { throw ObscuraError.transport("mock closed") }
    sent.append(text)
    await gate.waitForRelease()
    guard !closed else { throw ObscuraError.closed }
  }

  func receive() async throws -> String {
    if closed { throw ObscuraError.closed }
    return try await withCheckedThrowingContinuation { continuation in
      precondition(receiveWaiter == nil)
      receiveWaiter = continuation
    }
  }

  func close() async {
    guard !closed else { return }
    closed = true
    connected = false
    receiveWaiter?.resume(throwing: ObscuraError.closed)
    receiveWaiter = nil
  }

  func sentFrames() -> [String] { sent }
}

actor GatedStopProcess: EngineProcessHandle {
  private let base: EngineProcess
  private let gate: StopGate

  init(base: EngineProcess, gate: StopGate) {
    self.base = base
    self.gate = gate
  }

  func waitForExit() async throws -> EngineExit { try await base.waitForExit() }
  func isRunning() async -> Bool { await base.isRunning() }
  func diagnosticSnapshot() async -> String { await base.diagnosticSnapshot() }

  func stop() async throws -> EngineExit {
    await gate.waitForRelease()
    return try await base.stop()
  }

  nonisolated func terminateImmediately() { base.terminateImmediately() }
}

/// Holds only the first process-stop completion so a recovery cleanup can
/// finish while the original terminal finalizer remains suspended.
actor FirstStopGate {
  private var firstStopClaimed = false
  private var firstStopEntered = false
  private var released = false
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func waitForFirstStopRelease() async {
    guard !firstStopClaimed else { return }
    firstStopClaimed = true
    firstStopEntered = true
    if released { return }
    await withCheckedContinuation { continuation in
      if released {
        continuation.resume()
      } else {
        releaseWaiters.append(continuation)
      }
    }
  }

  func firstStopWasEntered() -> Bool { firstStopEntered }

  func releaseFirstStop() {
    guard !released else { return }
    released = true
    let releaseWaiters = releaseWaiters
    self.releaseWaiters.removeAll(keepingCapacity: false)
    for waiter in releaseWaiters { waiter.resume() }
  }
}

actor FirstStopGatedProcess: EngineProcessHandle {
  private let base: any EngineProcessHandle
  private let gate: FirstStopGate

  init(base: any EngineProcessHandle, gate: FirstStopGate) {
    self.base = base
    self.gate = gate
  }

  func waitForExit() async throws -> EngineExit { try await base.waitForExit() }
  func isRunning() async -> Bool { await base.isRunning() }
  func diagnosticSnapshot() async -> String { await base.diagnosticSnapshot() }

  func stop() async throws -> EngineExit {
    await gate.waitForFirstStopRelease()
    return try await base.stop()
  }

  nonisolated func terminateImmediately() { base.terminateImmediately() }
}

actor CompletionFlag {
  private(set) var completed = false
  func markCompleted() { completed = true }
}

actor ReplacementLaunchGate {
  private var launchCount = 0
  private var replacementStarted = false
  private var released = false
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func launch(_ launch: EngineProcessLaunch) async throws -> any EngineProcessHandle {
    launchCount += 1
    if launchCount == 2 {
      replacementStarted = true
      if !released {
        await withCheckedContinuation { continuation in
          releaseWaiters.append(continuation)
        }
      }
    }
    return try await EngineProcess.launch(launch)
  }

  func didStartReplacement() -> Bool { replacementStarted }

  func replacementLaunchCount() -> Int { launchCount }

  func releaseReplacement() {
    guard !released else { return }
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }
}

actor ScriptedWebSocketTransport: WebSocketTransport {
  enum Behavior: Sendable {
    case success(JSONValue)
    case cdpError(code: Int, message: String)
    case wrongResponseID
    case malformed
    case sessionScopedResponse
    case sessionScopedEvent
    case matchingRequestSession
    case vendoredBootstrap
    case invalidEventParams
    case validEventThenSuccess
    case noResponse
    case sendFailure
  }

  private let behavior: Behavior
  private var connected = false
  private var closed = false
  private var queuedMessages: [String] = []
  private var receiveWaiter: CheckedContinuation<String, Error>?
  private var sent: [String] = []

  init(behavior: Behavior = .success(.object([:]))) {
    self.behavior = behavior
  }

  func connect() async throws {
    guard !connected, !closed else { throw ObscuraError.invalidState("mock connect") }
    connected = true
  }

  func send(text: String) async throws {
    guard connected, !closed else { throw ObscuraError.transport("mock closed") }
    sent.append(text)
    if case .sendFailure = behavior {
      throw ObscuraError.transport("mock send failure")
    }
    guard case .noResponse = behavior else {
      let object = try decodeObject(text)
      guard let id = object["id"] as? Int else {
        throw ObscuraError.protocolViolation("mock request id missing")
      }
      let sessionID = object["sessionId"] as? String
      let response: String
      switch behavior {
      case .success(let result):
        response = try encodeResponse(id: id, result: result)
      case .cdpError(let code, let message):
        response = try encodeError(id: id, code: code, message: message)
      case .wrongResponseID:
        response = try encodeResponse(id: id + 1, result: .object([:]))
      case .malformed:
        response = "{malformed"
      case .sessionScopedResponse:
        response = "{\"id\":\(id),\"sessionId\":\"unexpected\",\"result\":{}}"
      case .sessionScopedEvent:
        enqueue("{\"method\":\"Page.loadEventFired\",\"sessionId\":\"unexpected\",\"params\":{}}")
        response = try encodeResponse(id: id, result: .object([:]))
      case .matchingRequestSession:
        response = try encodeResponse(id: id, result: .object([:]), sessionID: sessionID)
      case .vendoredBootstrap:
        response = try vendoredBootstrapResponse(
          id: id,
          method: try requiredMethod(from: object),
          sessionID: sessionID
        )
      case .invalidEventParams:
        enqueue("{\"method\":\"Page.loadEventFired\",\"params\":[]}")
        response = try encodeResponse(id: id, result: .object([:]))
      case .validEventThenSuccess:
        enqueue("{\"method\":\"Page.loadEventFired\",\"params\":{\"timestamp\":1}}")
        response = try encodeResponse(id: id, result: .object([:]))
      case .noResponse, .sendFailure:
        return
      }
      enqueue(response)
      return
    }
  }

  func receive() async throws -> String {
    if !queuedMessages.isEmpty { return queuedMessages.removeFirst() }
    if closed { throw ObscuraError.closed }
    return try await withCheckedThrowingContinuation { continuation in
      precondition(receiveWaiter == nil)
      receiveWaiter = continuation
    }
  }

  func close() async {
    guard !closed else { return }
    closed = true
    connected = false
    receiveWaiter?.resume(throwing: ObscuraError.closed)
    receiveWaiter = nil
  }

  func sentFrames() -> [String] { sent }

  private func enqueue(_ message: String) {
    if let waiter = receiveWaiter {
      receiveWaiter = nil
      waiter.resume(returning: message)
    } else {
      queuedMessages.append(message)
    }
  }

  private func decodeObject(_ text: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else {
      throw ObscuraError.protocolViolation("mock request is not an object")
    }
    return value
  }

  private func encodeResponse(id: Int, result: JSONValue, sessionID: String? = nil) throws -> String
  {
    struct Response: Encodable {
      let id: Int
      let result: JSONValue
      let sessionID: String?

      enum CodingKeys: String, CodingKey {
        case id, result
        case sessionID = "sessionId"
      }
    }
    return String(
      decoding: try JSONEncoder().encode(Response(id: id, result: result, sessionID: sessionID)),
      as: UTF8.self)
  }

  private func vendoredBootstrapResponse(id: Int, method: String, sessionID: String?) throws
    -> String
  {
    switch method {
    case "Target.createTarget":
      return try encodeResponse(
        id: id,
        result: .object(["targetId": .string("page-1")])
      )
    case "Target.attachToTarget":
      return try encodeResponse(
        id: id,
        result: .object(["sessionId": .string("page-1-session")])
      )
    case "Page.enable", "Runtime.enable", "Network.enable":
      guard sessionID == "page-1-session" else {
        throw ObscuraError.protocolViolation("mock page request is missing its session")
      }
      return try encodeResponse(id: id, result: .object([:]), sessionID: sessionID)
    case "Browser.getVersion":
      guard sessionID == nil else {
        throw ObscuraError.protocolViolation("mock browser request must be unscoped")
      }
      return try encodeResponse(id: id, result: .object([:]))
    default:
      throw ObscuraError.protocolViolation("mock does not support \(method)")
    }
  }

  private func requiredMethod(from object: [String: Any]) throws -> String {
    guard let method = object["method"] as? String else {
      throw ObscuraError.protocolViolation("mock request method missing")
    }
    return method
  }

  private func encodeError(id: Int, code: Int, message: String) throws -> String {
    struct Body: Encodable {
      let code: Int
      let message: String
    }
    struct Response: Encodable {
      let id: Int
      let error: Body
    }
    return String(
      decoding: try JSONEncoder().encode(
        Response(id: id, error: Body(code: code, message: message))), as: UTF8.self)
  }
}
