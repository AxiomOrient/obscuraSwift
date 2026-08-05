import Foundation

public struct EngineExit: Sendable, Equatable, Codable {
  public let exitCode: Int32?
  public let signal: Int32?

  public init(exitCode: Int32? = nil, signal: Int32? = nil) {
    self.exitCode = exitCode
    self.signal = signal
  }
}

public enum ObscuraError: Error, Sendable, Equatable {
  case invalidConfiguration(String)
  case executableNotFound(String)
  case executableRejected(String)
  case processLaunchFailed(errno: Int32, message: String)
  case engineExited(exit: EngineExit, diagnostics: String)
  case startupTimedOut
  case controlPlane(String)
  case transport(String)
  case protocolViolation(String)
  case cdp(code: Int, message: String)
  case javaScript(String)
  case unsupportedJavaScriptResult(String)
  case operationTimedOut(String)
  case cancelled(String)
  case sessionBusy(limit: Int)
  case invalidState(String)
  case quarantined(String)
  case closed
  case elementNotFound(String)
  case cookieRejected(String)
  case incompatibleCheckpoint(String)
  case recoveryFailed(primary: String, recovery: String)
  case resourceLimit(String)

  internal var requiresQuarantine: Bool {
    switch self {
    case .engineExited, .transport, .protocolViolation, .operationTimedOut, .cancelled:
      true
    default:
      false
    }
  }
}

extension ObscuraError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .invalidConfiguration(let message): "invalid configuration: \(message)"
    case .executableNotFound(let path): "engine executable not found: \(path)"
    case .executableRejected(let message): "engine executable rejected: \(message)"
    case .processLaunchFailed(let errno, let message):
      "engine launch failed (errno \(errno)): \(message)"
    case .engineExited(let exit, let diagnostics):
      "engine exited (code=\(exit.exitCode.map(String.init) ?? "nil"), signal=\(exit.signal.map(String.init) ?? "nil")): \(diagnostics)"
    case .startupTimedOut: "engine startup timed out"
    case .controlPlane(let message): "control-plane failure: \(message)"
    case .transport(let message): "transport failure: \(message)"
    case .protocolViolation(let message): "protocol violation: \(message)"
    case .cdp(let code, let message): "CDP error \(code): \(message)"
    case .javaScript(let message): "JavaScript exception: \(message)"
    case .unsupportedJavaScriptResult(let message): "unsupported JavaScript result: \(message)"
    case .operationTimedOut(let operation): "operation timed out: \(operation)"
    case .cancelled(let operation): "operation cancelled: \(operation)"
    case .sessionBusy(let limit): "session operation queue is full (limit \(limit))"
    case .invalidState(let message): "invalid state transition: \(message)"
    case .quarantined(let message): "session is quarantined: \(message)"
    case .closed: "session is closed"
    case .elementNotFound(let selector): "element not found: \(selector)"
    case .cookieRejected(let message): "cookie rejected: \(message)"
    case .incompatibleCheckpoint(let message): "incompatible checkpoint: \(message)"
    case .recoveryFailed(let primary, let recovery):
      "recovery failed (primary: \(primary); recovery: \(recovery))"
    case .resourceLimit(let message): "resource limit exceeded: \(message)"
    }
  }
}
