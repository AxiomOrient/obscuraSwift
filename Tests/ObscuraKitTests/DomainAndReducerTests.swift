import Foundation
import XCTest

@testable import ObscuraKit

final class DomainAndReducerTests: XCTestCase, @unchecked Sendable {
  func testJSONValueRoundTripsEveryCase() throws {
    let value = JSONValue.object([
      "null": .null,
      "bool": .bool(true),
      "number": .number(42.5),
      "string": .string("한글 Browser.close"),
      "array": .array([.number(1), .string("x")]),
    ])
    let data = try JSONEncoder().encode(value)
    XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
  }

  func testJSONValueRejectsNonFiniteNumber() {
    XCTAssertThrowsError(try JSONEncoder().encode(JSONValue.number(.infinity)))
    XCTAssertThrowsError(try JSONEncoder().encode(JSONValue.number(.nan)))
  }

  func testCSSSelectorValidation() throws {
    XCTAssertThrowsError(try CSSSelector(""))
    XCTAssertThrowsError(try CSSSelector(" #id"))
    XCTAssertThrowsError(try CSSSelector("#id\0"))
    XCTAssertEqual(try CSSSelector("#id").rawValue, "#id")
  }

  func testCookieValidationAndSameSiteRule() throws {
    XCTAssertThrowsError(try Cookie(name: "sid", value: "x", domain: "."))
    XCTAssertThrowsError(try Cookie(name: "sid", value: "x", domain: "..."))
    XCTAssertThrowsError(
      try Cookie(name: "sid", value: "x", domain: "example.test", sameSite: SameSite.none)
    )
    let cookie = try Cookie(
      name: "sid",
      value: "Browser.close",
      domain: "example.test",
      secure: true,
      sameSite: SameSite.none
    )
    XCTAssertEqual(cookie.value, "Browser.close")
  }

  func testLaunchConfigurationRejectsUnsafeBounds() throws {
    let executable = EngineExecutable.explicit(try systemTrueExecutable())
    XCTAssertThrowsError(try LaunchConfiguration(executable: executable, startupTimeout: .zero))
    XCTAssertThrowsError(try LaunchConfiguration(executable: executable, diagnosticByteLimit: 10))
    XCTAssertThrowsError(try LaunchConfiguration(executable: executable, maximumMessageBytes: 10))
    XCTAssertThrowsError(
      try LaunchConfiguration(executable: executable, maximumQueuedOperations: 0))
    XCTAssertNoThrow(try LaunchConfiguration(executable: executable))
  }

  func testChromeModeRejectsObscuraOnlyStealthOption() throws {
    XCTAssertThrowsError(
      try LaunchConfiguration(
        executable: .chrome(executable: try systemTrueExecutable()),
        stealth: true
      )
    ) { error in
      XCTAssertEqual(
        error as? ObscuraError,
        .invalidConfiguration("stealth is only supported by the Obscura engine, not Chrome mode")
      )
    }
  }

  func testChromeModeConvenienceConfigurationUsesChromeExecutable() throws {
    let executable = try systemTrueExecutable()

    let configuration = try LaunchConfiguration.chrome(executable: executable)

    XCTAssertEqual(configuration.executable, .chrome(executable: executable))
  }

  func testCodableBoundariesRevalidateDomainInvariants() throws {
    let selectorData = Data(#"{"rawValue":""}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(CSSSelector.self, from: selectorData))

    let invalidCookie = Data(
      #"{"name":"sid","value":"x","domain":"example.test","path":"/","secure":false,"httpOnly":false,"sameSite":"None"}"#
        .utf8
    )
    XCTAssertThrowsError(try JSONDecoder().decode(Cookie.self, from: invalidCookie))

    let invalidCompatibility = Data(
      #"{"proxy":"file:///tmp/proxy","userAgent":null,"stealth":false,"allowPrivateNetwork":false}"#
        .utf8
    )
    XCTAssertThrowsError(
      try JSONDecoder().decode(SessionCompatibility.self, from: invalidCompatibility))

    let validCookie = try Cookie(
      name: "sid",
      value: "x",
      domain: "example.test",
      secure: true,
      sameSite: SameSite.none
    )
    let validSelector = try CSSSelector("#id")
    XCTAssertEqual(
      try JSONDecoder().decode(Cookie.self, from: JSONEncoder().encode(validCookie)),
      validCookie
    )
    XCTAssertEqual(
      try JSONDecoder().decode(CSSSelector.self, from: JSONEncoder().encode(validSelector)),
      validSelector
    )
  }

  func testCheckpointRejectsUnboundedOrNonFiniteState() throws {
    let compatibility = try SessionCompatibility(
      proxy: nil,
      userAgent: nil,
      stealth: false,
      allowPrivateNetwork: false
    )
    let cookie = try Cookie(name: "sid", value: "x", domain: "example.test")
    XCTAssertThrowsError(
      try SessionCheckpoint(
        compatibility: compatibility,
        cookies: Array(repeating: cookie, count: SessionCheckpoint.maximumCookieCount + 1)
      )
    )
    XCTAssertThrowsError(
      try SessionCheckpoint(
        compatibility: compatibility,
        cookies: [],
        createdAt: Date(timeIntervalSince1970: .infinity)
      )
    )
    let duplicateDomainForm = try Cookie(
      name: "sid",
      value: "other",
      domain: ".EXAMPLE.TEST"
    )
    XCTAssertThrowsError(
      try SessionCheckpoint(
        compatibility: compatibility,
        cookies: [cookie, duplicateDomainForm]
      )
    )
  }

  func testCheckpointRestorableCookiesDropsOnlyExpiredCookies() throws {
    let compatibility = try SessionCompatibility(
      proxy: nil,
      userAgent: nil,
      stealth: false,
      allowPrivateNetwork: false
    )
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let sessionCookie = try Cookie(name: "session", value: "s", domain: "example.test")
    let expired = try Cookie(
      name: "expired",
      value: "x",
      domain: "example.test",
      expires: now.addingTimeInterval(-1)
    )
    let expiresNow = try Cookie(
      name: "expires-now",
      value: "x",
      domain: "example.test",
      expires: now
    )
    let active = try Cookie(
      name: "active",
      value: "a",
      domain: "example.test",
      expires: now.addingTimeInterval(60)
    )
    let checkpoint = try SessionCheckpoint(
      compatibility: compatibility,
      cookies: [sessionCookie, expired, expiresNow, active],
      createdAt: now.addingTimeInterval(-10)
    )

    XCTAssertEqual(try checkpoint.restorableCookies(at: now), [sessionCookie, active])
    XCTAssertThrowsError(
      try checkpoint.restorableCookies(at: Date(timeIntervalSince1970: .infinity)))
  }

  func testLaunchConfigurationValidatesExternalTextBoundaries() throws {
    let executable = EngineExecutable.explicit(try systemTrueExecutable())
    XCTAssertThrowsError(
      try LaunchConfiguration(executable: executable, proxy: "file:///tmp/proxy"))
    XCTAssertThrowsError(
      try LaunchConfiguration(executable: executable, proxy: " http://127.0.0.1:8080"))
    XCTAssertThrowsError(
      try LaunchConfiguration(executable: executable, userAgent: "agent\nInjected: yes"))
    XCTAssertNoThrow(
      try LaunchConfiguration(
        executable: executable,
        proxy: "socks5://127.0.0.1:1080",
        userAgent: "ObscuraSwift/1.0"
      )
    )
  }

  func testReducerExecutesExplicitStartupStateMachine() throws {
    var state = SessionState(
      id: SessionID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
    var transition = try SessionReducer.reduce(state: state, event: .startRequested)
    XCTAssertEqual(transition.state.phase, .starting)
    XCTAssertEqual(transition.state.startupStage, .launchingProcess)
    XCTAssertEqual(transition.effects, [.launchProcess])

    state = transition.state
    transition = try SessionReducer.reduce(state: state, event: .processLaunched)
    XCTAssertEqual(transition.state.startupStage, .discoveringControlPlane)
    XCTAssertEqual(transition.effects, [.discoverControlPlane])

    state = transition.state
    transition = try SessionReducer.reduce(state: state, event: .controlPlaneDiscovered)
    XCTAssertEqual(transition.state.startupStage, .connectingTransport)
    XCTAssertEqual(transition.effects, [.connectTransport])

    state = transition.state
    transition = try SessionReducer.reduce(state: state, event: .transportConnected)
    XCTAssertEqual(transition.state.startupStage, .initializingProtocol)
    XCTAssertEqual(transition.effects, [.initializeProtocol])

    transition = try SessionReducer.reduce(state: transition.state, event: .protocolInitialized)
    XCTAssertEqual(transition.state.phase, .ready)
    XCTAssertNil(transition.state.startupStage)
    XCTAssertTrue(transition.effects.isEmpty)
  }

  func testReducerSerializesOperationAndAdvancesGenerationOnlyForMutation() throws {
    var state = try readyState()
    let readID = OperationID(1)
    var transition = try SessionReducer.reduce(
      state: state,
      event: .operationRequested(id: readID, operation: .readDOM)
    )
    XCTAssertEqual(transition.state.phase, .executing)
    XCTAssertEqual(transition.effects, [.dispatch(id: readID, operation: .readDOM)])
    transition = try SessionReducer.reduce(
      state: transition.state,
      event: .operationSucceeded(id: readID, operation: .readDOM)
    )
    XCTAssertEqual(transition.state.generation, 0)

    let mutationID = OperationID(2)
    state = transition.state
    transition = try SessionReducer.reduce(
      state: state,
      event: .operationRequested(id: mutationID, operation: .mutateDOM)
    )
    transition = try SessionReducer.reduce(
      state: transition.state,
      event: .operationSucceeded(id: mutationID, operation: .mutateDOM)
    )
    XCTAssertEqual(transition.state.generation, 1)
    XCTAssertEqual(transition.state.phase, .ready)
  }

  func testReducerNonterminalFailureReturnsReady() throws {
    let id = OperationID(10)
    var state = try readyState()
    state = try SessionReducer.reduce(
      state: state,
      event: .operationRequested(id: id, operation: .evaluate)
    ).state
    let transition = try SessionReducer.reduce(
      state: state,
      event: .operationFailed(id: id, error: .javaScript("boom"), terminal: false)
    )
    XCTAssertEqual(transition.state.phase, .ready)
    XCTAssertNil(transition.state.failure)
    XCTAssertTrue(transition.effects.isEmpty)
  }

  func testReducerTerminalFailureQuarantinesAndRequestsShutdown() throws {
    let id = OperationID(11)
    var state = try readyState()
    state = try SessionReducer.reduce(
      state: state,
      event: .operationRequested(id: id, operation: .evaluate)
    ).state
    let error = ObscuraError.operationTimedOut("Runtime.evaluate")
    let transition = try SessionReducer.reduce(
      state: state,
      event: .operationFailed(id: id, error: error, terminal: true)
    )
    XCTAssertEqual(transition.state.phase, .quarantined)
    XCTAssertEqual(transition.state.failure, error)
    XCTAssertEqual(transition.effects, [.shutdown])
  }

  func testReducerRecordsAndCompletesOperationInterruptedBySupervision() throws {
    let id = OperationID(12)
    var state = try readyState()
    state = try SessionReducer.reduce(
      state: state,
      event: .operationRequested(id: id, operation: .evaluate)
    ).state

    let failure = ObscuraError.transport("lost")
    var transition = try SessionReducer.reduce(
      state: state,
      event: .supervisionFailed(failure)
    )
    XCTAssertEqual(transition.state.phase, .quarantined)
    XCTAssertNil(transition.state.activeOperation)
    XCTAssertEqual(transition.state.interruptedOperation, id)
    XCTAssertEqual(transition.effects, [.shutdown])

    transition = try SessionReducer.reduce(
      state: transition.state,
      event: .interruptedOperationCompleted(id: id)
    )
    XCTAssertEqual(transition.state.phase, .quarantined)
    XCTAssertNil(transition.state.interruptedOperation)
    XCTAssertEqual(transition.state.failure, failure)
    XCTAssertTrue(transition.effects.isEmpty)
  }

  func testReducerRecordsOperationInterruptedByCloseThroughClosedState() throws {
    let id = OperationID(13)
    var state = try readyState()
    state = try SessionReducer.reduce(
      state: state,
      event: .operationRequested(id: id, operation: .evaluate)
    ).state

    var transition = try SessionReducer.reduce(state: state, event: .closeRequested)
    XCTAssertEqual(transition.state.phase, .closing)
    XCTAssertEqual(transition.state.interruptedOperation, id)
    transition = try SessionReducer.reduce(state: transition.state, event: .shutdownCompleted)
    XCTAssertEqual(transition.state.phase, .closed)
    XCTAssertEqual(transition.state.interruptedOperation, id)
    transition = try SessionReducer.reduce(
      state: transition.state,
      event: .interruptedOperationCompleted(id: id)
    )
    XCTAssertEqual(transition.state.phase, .closed)
    XCTAssertNil(transition.state.interruptedOperation)
  }

  func testReducerRecoveryCreatesReplacementAndClosesOldSession() throws {
    let error = ObscuraError.transport("lost")
    var state = try readyState()
    state = try SessionReducer.reduce(state: state, event: .supervisionFailed(error)).state
    XCTAssertEqual(state.phase, .quarantined)
    let checkpoint = try SessionCheckpoint(
      compatibility: try SessionCompatibility(
        proxy: nil, userAgent: nil, stealth: false, allowPrivateNetwork: true),
      cookies: []
    )
    var transition = try SessionReducer.reduce(state: state, event: .recoveryRequested(checkpoint))
    XCTAssertEqual(transition.state.phase, .recovering)
    XCTAssertEqual(transition.effects, [.shutdown, .launchReplacement(checkpoint)])
    transition = try SessionReducer.reduce(state: transition.state, event: .replacementSucceeded)
    XCTAssertEqual(transition.state.phase, .closed)
  }

  func testReducerRejectsInvalidEventsAndMismatchedCompletion() throws {
    let idle = SessionState()
    XCTAssertThrowsError(try SessionReducer.reduce(state: idle, event: .protocolInitialized))

    let id = OperationID(1)
    var state = try readyState()
    state = try SessionReducer.reduce(
      state: state,
      event: .operationRequested(id: id, operation: .evaluate)
    ).state
    XCTAssertThrowsError(
      try SessionReducer.reduce(
        state: state,
        event: .operationSucceeded(id: OperationID(2), operation: .evaluate)
      )
    )
  }

  func testReducerDetectsGenerationOverflow() throws {
    var state = try readyState()
    state.generation = UInt64.max
    let id = OperationID(1)
    state = try SessionReducer.reduce(
      state: state,
      event: .operationRequested(id: id, operation: .mutateDOM)
    ).state
    XCTAssertThrowsError(
      try SessionReducer.reduce(
        state: state,
        event: .operationSucceeded(id: id, operation: .mutateDOM)
      )
    ) { error in
      XCTAssertEqual(error as? ObscuraError, .resourceLimit("document generation overflow"))
    }
  }

  func testCloseIsIdempotentAndTerminal() throws {
    var transition = try SessionReducer.reduce(state: SessionState(), event: .closeRequested)
    XCTAssertEqual(transition.state.phase, .closed)
    transition = try SessionReducer.reduce(state: transition.state, event: .closeRequested)
    XCTAssertEqual(transition.state.phase, .closed)
    XCTAssertTrue(transition.effects.isEmpty)
  }

  private func readyState() throws -> SessionState {
    var state = SessionState()
    for event in [
      SessionEvent.startRequested,
      .processLaunched,
      .controlPlaneDiscovered,
      .transportConnected,
      .protocolInitialized,
    ] {
      state = try SessionReducer.reduce(state: state, event: event).state
    }
    return state
  }
}
