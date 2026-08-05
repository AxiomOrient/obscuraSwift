import Foundation

internal enum StartupStage: String, Sendable, Equatable, Codable {
  case launchingProcess
  case discoveringControlPlane
  case connectingTransport
  case initializingProtocol
}

internal enum SessionOperation: Sendable, Equatable {
  case navigate(URL)
  case evaluate
  case readDOM
  case mutateDOM
  case readCookies
  case writeCookies

  var mutatesDocument: Bool {
    switch self {
    case .navigate, .mutateDOM:
      true
    default:
      false
    }
  }
}

internal struct SessionState: Sendable, Equatable {
  let id: SessionID
  var phase: SessionPhase
  var startupStage: StartupStage?
  var generation: UInt64
  var activeOperation: OperationID?
  // A terminal transition may interrupt an in-flight actor operation while its
  // async effect is still unwinding. Keeping that operation identifier in the
  // pure state makes the eventual late completion an explicit event instead of
  // an invalid transition. This coordination detail is intentionally omitted
  // from the public snapshot.
  internal var interruptedOperation: OperationID?
  var failure: ObscuraError?

  init(id: SessionID = SessionID()) {
    self.id = id
    self.phase = .idle
    self.startupStage = nil
    self.generation = 0
    self.activeOperation = nil
    self.interruptedOperation = nil
    self.failure = nil
  }

  var snapshot: SessionSnapshot {
    SessionSnapshot(
      id: id,
      phase: phase,
      generation: generation,
      activeOperation: activeOperation,
      failure: failure?.description
    )
  }
}

internal enum SessionEvent: Sendable, Equatable {
  case startRequested
  case processLaunched
  case controlPlaneDiscovered
  case transportConnected
  case protocolInitialized
  case operationRequested(id: OperationID, operation: SessionOperation)
  case operationSucceeded(id: OperationID, operation: SessionOperation)
  case operationFailed(id: OperationID, error: ObscuraError, terminal: Bool)
  case interruptedOperationCompleted(id: OperationID)
  case supervisionFailed(ObscuraError)
  case closeRequested
  case shutdownCompleted
  case shutdownFailed(ObscuraError)
  case recoveryRequested(SessionCheckpoint)
  case replacementSucceeded
  case replacementFailed(ObscuraError)
}

internal enum SessionEffect: Sendable, Equatable {
  case launchProcess
  case discoverControlPlane
  case connectTransport
  case initializeProtocol
  case dispatch(id: OperationID, operation: SessionOperation)
  case shutdown
  case launchReplacement(SessionCheckpoint)
}

internal struct SessionTransition: Sendable, Equatable {
  let state: SessionState
  let effects: [SessionEffect]
}

internal enum SessionReducer {
  static func reduce(state original: SessionState, event: SessionEvent) throws
    -> SessionTransition
  {
    var state = original
    var effects: [SessionEffect] = []

    switch (state.phase, event) {
    case (.idle, .startRequested):
      state.phase = .starting
      state.startupStage = .launchingProcess
      effects = [.launchProcess]

    case (.starting, .processLaunched) where state.startupStage == .launchingProcess:
      state.startupStage = .discoveringControlPlane
      effects = [.discoverControlPlane]

    case (.starting, .controlPlaneDiscovered) where state.startupStage == .discoveringControlPlane:
      state.startupStage = .connectingTransport
      effects = [.connectTransport]

    case (.starting, .transportConnected) where state.startupStage == .connectingTransport:
      state.startupStage = .initializingProtocol
      effects = [.initializeProtocol]

    case (.starting, .protocolInitialized) where state.startupStage == .initializingProtocol:
      state.phase = .ready
      state.startupStage = nil

    case (.ready, .operationRequested(let id, let operation)):
      guard state.activeOperation == nil else {
        throw ObscuraError.invalidState("ready state contains active operation")
      }
      state.phase = .executing
      state.activeOperation = id
      effects = [.dispatch(id: id, operation: operation)]

    case (.executing, .operationSucceeded(let id, let operation)):
      try requireActive(id, in: state)
      state.activeOperation = nil
      if operation.mutatesDocument {
        guard state.generation < UInt64.max else {
          throw ObscuraError.resourceLimit("document generation overflow")
        }
        state.generation += 1
      }
      state.phase = .ready

    case (.executing, .operationFailed(let id, let error, let terminal)):
      try requireActive(id, in: state)
      state.activeOperation = nil
      if terminal {
        state.phase = .quarantined
        state.failure = error
        effects = [.shutdown]
      } else {
        state.phase = .ready
      }

    case (.starting, .supervisionFailed(let error)),
      (.ready, .supervisionFailed(let error)),
      (.executing, .supervisionFailed(let error)):
      if state.phase == .executing {
        state.interruptedOperation = state.activeOperation
      }
      state.phase = .quarantined
      state.startupStage = nil
      state.activeOperation = nil
      state.failure = error
      effects = [.shutdown]

    case (.idle, .closeRequested):
      state.phase = .closed

    case (.starting, .closeRequested),
      (.ready, .closeRequested),
      (.executing, .closeRequested),
      (.quarantined, .closeRequested),
      (.recovering, .closeRequested):
      if state.phase == .executing {
        state.interruptedOperation = state.activeOperation
      }
      state.phase = .closing
      state.startupStage = nil
      state.activeOperation = nil
      effects = [.shutdown]

    case (.closing, .closeRequested), (.closed, .closeRequested):
      break

    case (.closing, .shutdownCompleted), (.quarantined, .shutdownCompleted):
      if state.phase == .closing {
        state.phase = .closed
      }

    case (.closing, .shutdownFailed(let error)):
      state.phase = .closed
      state.failure = merge(primary: state.failure, secondary: error)

    case (.quarantined, .shutdownFailed(let error)):
      state.failure = merge(primary: state.failure, secondary: error)

    case (.quarantined, .recoveryRequested(let checkpoint)):
      state.phase = .recovering
      effects = [.shutdown, .launchReplacement(checkpoint)]

    case (.recovering, .replacementSucceeded):
      state.phase = .closed

    case (.recovering, .replacementFailed(let error)):
      state.phase = .closed
      state.failure = merge(primary: state.failure, secondary: error)

    case (.closed, .shutdownCompleted), (.closed, .shutdownFailed):
      break

    case (.quarantined, .interruptedOperationCompleted(let id)),
      (.recovering, .interruptedOperationCompleted(let id)),
      (.closing, .interruptedOperationCompleted(let id)),
      (.closed, .interruptedOperationCompleted(let id)):
      try requireInterrupted(id, in: state)
      state.interruptedOperation = nil

    default:
      throw ObscuraError.invalidState(
        "event \(String(describing: event)) is not valid in phase \(state.phase.rawValue)")
    }

    try validate(state)
    return SessionTransition(state: state, effects: effects)
  }

  /// Records an internal state-machine invariant failure without hiding it.
  ///
  /// This is the last-resort transition used only when the actor detects that
  /// its own event sequencing is inconsistent with the pure reducer. The
  /// session becomes unusable and must release all external resources.
  internal static func forceQuarantined(
    state original: SessionState,
    error: ObscuraError
  ) -> SessionTransition {
    var state = original
    if state.phase == .executing {
      state.interruptedOperation = state.activeOperation
    }
    state.phase = .quarantined
    state.startupStage = nil
    state.activeOperation = nil
    state.failure = merge(primary: state.failure, secondary: error)
    return SessionTransition(state: state, effects: [.shutdown])
  }

  /// Records an internal failure while finalizing a nonthrowing close path.
  /// The error remains observable in the final session snapshot.
  internal static func forceClosed(
    state original: SessionState,
    error: ObscuraError
  ) -> SessionTransition {
    var state = original
    if state.phase == .executing {
      state.interruptedOperation = state.activeOperation
    }
    state.phase = .closed
    state.startupStage = nil
    state.activeOperation = nil
    state.failure = merge(primary: state.failure, secondary: error)
    return SessionTransition(state: state, effects: [])
  }

  private static func requireActive(_ id: OperationID, in state: SessionState) throws {
    guard state.activeOperation == id else {
      throw ObscuraError.invalidState(
        "operation completion \(id) does not match active \(state.activeOperation?.description ?? "nil")"
      )
    }
  }

  private static func requireInterrupted(_ id: OperationID, in state: SessionState) throws {
    guard state.interruptedOperation == id else {
      throw ObscuraError.invalidState(
        "interrupted operation completion \(id) does not match pending \(state.interruptedOperation?.description ?? "nil")"
      )
    }
  }

  private static func merge(primary: ObscuraError?, secondary: ObscuraError) -> ObscuraError {
    guard let primary else { return secondary }
    return .recoveryFailed(primary: primary.description, recovery: secondary.description)
  }

  private static func validate(_ state: SessionState) throws {
    if state.phase == .starting, state.startupStage == nil {
      throw ObscuraError.invalidState("starting state requires a startup stage")
    }
    if state.phase != .starting, state.startupStage != nil {
      throw ObscuraError.invalidState("startup stage escaped starting state")
    }
    if state.phase == .executing, state.activeOperation == nil {
      throw ObscuraError.invalidState("executing state requires an active operation")
    }
    if state.phase != .executing, state.activeOperation != nil {
      throw ObscuraError.invalidState("active operation escaped executing state")
    }
    if state.phase == .executing, state.interruptedOperation != nil {
      throw ObscuraError.invalidState("executing state cannot contain an interrupted operation")
    }
    if state.interruptedOperation != nil,
      ![SessionPhase.quarantined, .recovering, .closing, .closed].contains(state.phase)
    {
      throw ObscuraError.invalidState("interrupted operation escaped terminal coordination state")
    }
    if state.phase == .quarantined, state.failure == nil {
      throw ObscuraError.invalidState("quarantined state requires failure evidence")
    }
  }
}
