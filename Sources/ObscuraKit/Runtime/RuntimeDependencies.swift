import Foundation

internal protocol EngineProcessHandle: Sendable {
  func waitForExit() async throws -> EngineExit
  func isRunning() async -> Bool
  func diagnosticSnapshot() async -> String
  func stop() async throws -> EngineExit

  /// Best-effort, non-suspending containment used only when the owner is
  /// deinitialized before an orderly `close()`. It must never report success;
  /// normal shutdown remains the explicit async `stop()` path.
  nonisolated func terminateImmediately()
}

extension EngineProcess: EngineProcessHandle {}

internal struct RuntimeDependencies: Sendable {
  let launchProcess: @Sendable (EngineProcessLaunch) async throws -> any EngineProcessHandle
  let controlPlane: any EngineControlPlane
  let makeTransport: @Sendable (URL, Int) throws -> any WebSocketTransport
  let currentDate: @Sendable () -> Date

  init(
    launchProcess:
      @escaping @Sendable (EngineProcessLaunch) async throws -> any EngineProcessHandle,
    controlPlane: any EngineControlPlane,
    makeTransport: @escaping @Sendable (URL, Int) throws -> any WebSocketTransport,
    currentDate: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.launchProcess = launchProcess
    self.controlPlane = controlPlane
    self.makeTransport = makeTransport
    self.currentDate = currentDate
  }

  static let live = RuntimeDependencies(
    launchProcess: { try await EngineProcess.launch($0) },
    controlPlane: LoopbackEngineControlPlane(),
    makeTransport: { try FoundationWebSocketTransport(endpoint: $0, maximumMessageBytes: $1) }
  )
}
