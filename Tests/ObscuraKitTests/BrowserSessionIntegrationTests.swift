import Foundation
import XCTest

@testable import ObscuraKit

final class BrowserSessionIntegrationTests: XCTestCase, @unchecked Sendable {
  func testChromeModeControlsInstalledChromeWhenAvailable() async throws {
    let chrome = URL(
      fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      isDirectory: false
    )
    guard FileManager.default.isExecutableFile(atPath: chrome.path) else {
      throw XCTSkip("Google Chrome is not installed on this host")
    }

    let configuration = try LaunchConfiguration(
      executable: .chrome(executable: chrome),
      startupTimeout: .seconds(15),
      operationTimeout: .seconds(15)
    )
    let session = try await BrowserSession.launch(configuration)
    do {
      let html = """
        <title>Chrome Mode</title>
        <button id='probe' data-state='ready' onclick="this.dataset.clicked = 'yes'">ready</button>
        <input id='field' value='before'>
        """
      let url = dataURL(html)
      _ = try await session.navigate(to: url, waitUntil: .load)
      let title = try await session.title()
      let currentURL = try await session.currentURL()
      let content = try await session.content()
      let answer = try await session.evaluate("6 * 7", as: Int.self)
      XCTAssertEqual(title, "Chrome Mode")
      XCTAssertEqual(currentURL, url)
      XCTAssertTrue(content.contains("Chrome Mode"))
      XCTAssertEqual(answer, 42)
      let probe = await session.locator(try CSSSelector("#probe"))
      let text = try await probe.textContent()
      let state = try await probe.attribute("data-state")
      XCTAssertEqual(text, "ready")
      XCTAssertEqual(state, "ready")
      try await probe.invokeDOMClick()
      let clicked = try await session.evaluate(
        "document.querySelector('#probe').dataset.clicked", as: String.self)
      XCTAssertEqual(clicked, "yes")
      let field = await session.locator(try CSSSelector("#field"))
      try await field.setValue("after")
      let fieldValue = try await session.evaluate(
        "document.querySelector('#field').value", as: String.self)
      XCTAssertEqual(fieldValue, "after")
      let cookie = try Cookie(name: "chrome-mode", value: "verified", domain: "example.test")
      try await session.setCookies([cookie])
      let cookies = try await session.cookies()
      let checkpoint = try await session.checkpoint()
      XCTAssertTrue(cookies.contains(cookie))
      XCTAssertTrue(checkpoint.cookies.contains(cookie))
      await session.close()
      let snapshot = await session.snapshot()
      XCTAssertEqual(snapshot.phase, .closed)
    } catch {
      await session.close()
      throw error
    }
  }

  func testCoreNavigationEvaluationLocatorAndMutationContract() async throws {
    let fixture = try FixtureExecutable.make()
    defer { fixture.forceCleanup() }
    try await withSession(fixture) { session in
      let initial = await session.snapshot()
      XCTAssertEqual(initial.phase, .ready)
      XCTAssertEqual(initial.generation, 0)

      let html = """
        <html><head><title>Integration Page</title></head><body>
          <button id='button' data-kind='primary'>Press</button>
          <input id='field' value='old'>
        </body></html>
        """
      let url = dataURL(html)
      let navigation = try await session.navigate(to: url, waitUntil: .load)
      XCTAssertEqual(navigation.url, url)
      XCTAssertEqual(navigation.frameID, "main-frame")
      XCTAssertEqual(navigation.generation, 1)

      let title = try await session.title()
      let currentURL = try await session.currentURL()
      let content = try await session.content()
      XCTAssertEqual(title, "Integration Page")
      XCTAssertEqual(currentURL, url)
      XCTAssertTrue(content.contains("Integration Page"))

      let button = await session.locator(try CSSSelector("#button"))
      let buttonText = try await button.textContent()
      let kind = try await button.attribute("data-kind")
      let generationAfterRead = await session.snapshot().generation
      XCTAssertEqual(buttonText, "Press")
      XCTAssertEqual(kind, "primary")
      XCTAssertEqual(generationAfterRead, 1)

      try await button.invokeDOMClick()
      let generationAfterClick = await session.snapshot().generation
      XCTAssertEqual(generationAfterClick, 2)
      let buttonState = try await session.evaluateJSON(
        "globalThis.__fixtureElementState(\"#button\")")
      XCTAssertEqual(buttonState["clicked"], .bool(true))

      let field = await session.locator(try CSSSelector("#field"))
      try await field.setValue("new value")
      let generationAfterSet = await session.snapshot().generation
      XCTAssertEqual(generationAfterSet, 3)
      let fieldState = try await session.evaluateJSON(
        "globalThis.__fixtureElementState(\"#field\")")
      XCTAssertEqual(fieldState["value"], .string("new value"))
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testTypedJavaScriptBoundaryAndNonterminalErrors() async throws {
    struct Payload: Decodable, Sendable, Equatable {
      let answer: Int
      let text: String
    }
    let fixture = try FixtureExecutable.make()
    defer { fixture.forceCleanup() }
    try await withSession(fixture) { session in
      let arithmetic = try await session.evaluate("1 + 2", as: Int.self)
      let promise = try await session.evaluate("Promise.resolve(7)", as: Int.self)
      let payload = try await session.evaluate("({ answer: 42, text: 'ok' })", as: Payload.self)
      XCTAssertEqual(arithmetic, 3)
      XCTAssertEqual(promise, 7)
      XCTAssertEqual(payload, Payload(answer: 42, text: "ok"))

      do {
        let _: JSONValue = try await session.evaluate("undefined")
        XCTFail("expected unsupported result")
      } catch {
        guard case .unsupportedJavaScriptResult = error as? ObscuraError else {
          return XCTFail("unexpected error: \(error)")
        }
      }
      let afterUnsupported = await session.snapshot()
      XCTAssertEqual(afterUnsupported.phase, .ready)

      do {
        let _: JSONValue = try await session.evaluate("__fixture_unserializable__")
        XCTFail("expected unsupported serialization result")
      } catch {
        guard case .unsupportedJavaScriptResult(let message) = error as? ObscuraError else {
          return XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(message.contains("not JSON-serializable"))
      }
      let afterSerializationFailure = await session.snapshot()
      XCTAssertEqual(afterSerializationFailure.phase, .ready)

      do {
        let _: JSONValue = try await session.evaluate("__fixture_throw__")
        XCTFail("expected JavaScript exception")
      } catch {
        XCTAssertEqual(error as? ObscuraError, .javaScript("fixture JavaScript exception"))
      }
      let afterException = await session.snapshot()
      let followUp = try await session.evaluate("1 + 2", as: Int.self)
      XCTAssertEqual(afterException.phase, .ready)
      XCTAssertEqual(followUp, 3)
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testInvalidEngineCurrentURLIsTerminalProtocolFailure() async throws {
    let fixture = try FixtureExecutable.make(mode: "invalid-current-url")
    defer { fixture.forceCleanup() }
    let session = try await BrowserSession.launch(try fixture.configuration())
    do {
      _ = try await session.currentURL()
      XCTFail("expected invalid engine URL rejection")
    } catch {
      XCTAssertEqual(
        error as? ObscuraError,
        .protocolViolation("engine returned an invalid absolute page URL")
      )
    }
    let snapshot = await session.snapshot()
    XCTAssertEqual(snapshot.phase, .quarantined)
    await session.close()
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testInvalidHTTPNavigationURLIsRejectedBeforeDispatch() async throws {
    let fixture = try FixtureExecutable.make()
    defer { fixture.forceCleanup() }
    try await withSession(fixture) { session in
      let invalid = try XCTUnwrap(URL(string: "http:relative"))
      do {
        _ = try await session.navigate(to: invalid)
        XCTFail("expected invalid navigation URL")
      } catch {
        XCTAssertEqual(
          error as? ObscuraError,
          .invalidConfiguration("HTTP navigation URL must contain a host")
        )
      }
      let snapshot = await session.snapshot()
      XCTAssertEqual(snapshot.phase, .ready)
      let pageNavigateCalls = try fixture.requestRecords().filter {
        $0["method"] as? String == "Page.navigate"
      }
      XCTAssertTrue(pageNavigateCalls.isEmpty)
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testCookiePostconditionPreservesBrowserCloseSentinelAndConnection() async throws {
    let fixture = try FixtureExecutable.make()
    defer { fixture.forceCleanup() }
    try await withSession(fixture) { session in
      let cookie = try Cookie(
        name: "session",
        value: "Browser.close",
        domain: "example.test",
        secure: true,
        sameSite: SameSite.none
      )
      try await session.setCookies([cookie])
      let observed = try await session.cookies()
      let followUp = try await session.evaluate("1 + 2", as: Int.self)
      let snapshot = await session.snapshot()
      XCTAssertEqual(observed, [cookie])
      XCTAssertEqual(followUp, 3)
      XCTAssertEqual(snapshot.phase, .ready)
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testDuplicateCookieIdentityIsRejectedBeforeDispatch() async throws {
    let fixture = try FixtureExecutable.make()
    defer { fixture.forceCleanup() }
    try await withSession(fixture) { session in
      let first = try Cookie(name: "sid", value: "first", domain: "example.test")
      let duplicate = try Cookie(name: "sid", value: "second", domain: ".EXAMPLE.TEST")

      do {
        try await session.setCookies([first, duplicate])
        XCTFail("expected duplicate cookie identity rejection")
      } catch {
        guard case .invalidConfiguration(let message) = error as? ObscuraError else {
          return XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(message.contains("duplicate cookie identity"))
      }

      let sentSetCookies = try fixture.requestRecords().contains {
        $0["method"] as? String == "Network.setCookies"
      }
      XCTAssertFalse(sentSetCookies)
      let followUp = try await session.evaluate("1 + 2", as: Int.self)
      let snapshot = await session.snapshot()
      XCTAssertEqual(followUp, 3)
      XCTAssertEqual(snapshot.phase, .ready)
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testConcurrentCallsAreSerializedAndQueueLimitFailsExplicitly() async throws {
    let fixture = try FixtureExecutable.make(delaySeconds: 0.25)
    defer { fixture.forceCleanup() }
    let configuration = try fixture.configuration(
      operationTimeout: .seconds(1),
      maximumQueuedOperations: 1
    )
    let session = try await BrowserSession.launch(configuration)
    do {
      let first = Task { try await session.evaluate("__fixture_delay__", as: String.self) }
      let firstWasSent = await eventually {
        (try? fixture.requestRecords().contains { $0["method"] as? String == "Runtime.evaluate" })
          == true
      }
      XCTAssertTrue(firstWasSent)

      let second = Task { try await session.evaluate("1 + 2", as: Int.self) }
      try await Task.sleep(for: .milliseconds(20))
      do {
        let _: Int = try await session.evaluate("1 + 2")
        XCTFail("expected bounded queue rejection")
      } catch {
        XCTAssertEqual(error as? ObscuraError, .sessionBusy(limit: 1))
      }
      let firstValue = try await first.value
      let secondValue = try await second.value
      let snapshot = await session.snapshot()
      XCTAssertEqual(firstValue, "delayed")
      XCTAssertEqual(secondValue, 3)
      XCTAssertEqual(snapshot.phase, .ready)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testCancellingQueuedOperationPreventsCDPDispatch() async throws {
    let fixture = try FixtureExecutable.make(delaySeconds: 0.25)
    defer { fixture.forceCleanup() }
    let configuration = try fixture.configuration(
      operationTimeout: .seconds(1),
      maximumQueuedOperations: 1
    )
    let session = try await BrowserSession.launch(configuration)
    do {
      let first = Task { try await session.evaluate("__fixture_delay__", as: String.self) }
      let firstWasSent = await eventually {
        (try? fixture.requestRecords().contains { $0["method"] as? String == "Runtime.evaluate" })
          == true
      }
      XCTAssertTrue(firstWasSent)

      let queued = Task { try await session.evaluate("1 + 2", as: Int.self) }
      let queuedOperationWasAccepted = await eventually {
        await session.operationQueueDepth == 1
      }
      XCTAssertTrue(queuedOperationWasAccepted)
      queued.cancel()
      do {
        let _: Int = try await queued.value
        XCTFail("expected queued operation cancellation")
      } catch {
        XCTAssertEqual(error as? ObscuraError, .cancelled("queued operation"))
      }

      let cancellationReleasedPermit = await eventually {
        await session.operationQueueDepth == 0
      }
      XCTAssertTrue(cancellationReleasedPermit)
      let followUp = try await session.evaluate("1 + 2", as: Int.self)
      XCTAssertEqual(followUp, 3)

      let firstValue = try await first.value
      XCTAssertEqual(firstValue, "delayed")
      let evaluateRequests = try fixture.requestRecords().filter {
        $0["method"] as? String == "Runtime.evaluate"
      }
      XCTAssertEqual(evaluateRequests.count, 2)
      let snapshot = await session.snapshot()
      XCTAssertEqual(snapshot.phase, .ready)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testOperationTimeoutQuarantinesAndStopsEngine() async throws {
    let fixture = try FixtureExecutable.make(delaySeconds: 1.0)
    defer { fixture.forceCleanup() }
    let session = try await BrowserSession.launch(
      try fixture.configuration(operationTimeout: .seconds(2)))
    do {
      let _: String = try await session.evaluate("__fixture_delay__", timeout: .milliseconds(50))
      XCTFail("expected timeout")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .operationTimedOut("Runtime.evaluate"))
    }
    let snapshot = await session.snapshot()
    XCTAssertEqual(snapshot.phase, .quarantined)
    XCTAssertTrue(snapshot.failure?.contains("timed out") == true)
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
    await session.close()
    let closed = await session.snapshot()
    XCTAssertEqual(closed.phase, .closed)
  }

  func testExplicitRecoveryUsesFreshProcessAndRestoresCheckpointOnly() async throws {
    let fixture = try FixtureExecutable.make(delaySeconds: 1.0)
    defer { fixture.forceCleanup() }
    let configuration = try fixture.configuration(operationTimeout: .seconds(2))
    let original = try await BrowserSession.launch(configuration)
    let cookie = try Cookie(name: "sid", value: "abc", domain: "example.test")
    try await original.setCookies([cookie])
    let checkpoint = try await original.checkpoint()
    do {
      let _: String = try await original.evaluate("__fixture_delay__", timeout: .milliseconds(50))
      XCTFail("expected timeout")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .operationTimedOut("Runtime.evaluate"))
    }
    let originalID = await original.id
    let replacement = try await original.recover(from: checkpoint)
    do {
      let replacementID = await replacement.id
      let originalSnapshot = await original.snapshot()
      let replacementSnapshot = await replacement.snapshot()
      let cookies = try await replacement.cookies()
      let currentURL = try await replacement.currentURL()
      XCTAssertNotEqual(replacementID, originalID)
      XCTAssertEqual(originalSnapshot.phase, .closed)
      XCTAssertEqual(replacementSnapshot.phase, .ready)
      XCTAssertEqual(cookies, checkpoint.cookies)
      XCTAssertEqual(currentURL.absoluteString, "about:blank")
      await replacement.close()
    } catch {
      await replacement.close()
      throw error
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testRecoveryDropsCookiesThatExpiredAfterCheckpoint() async throws {
    let fixture = try FixtureExecutable.make(delaySeconds: 1.0)
    defer { fixture.forceCleanup() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let dependencies = RuntimeDependencies(
      launchProcess: { try await EngineProcess.launch($0) },
      controlPlane: LoopbackEngineControlPlane(),
      makeTransport: { endpoint, limit in
        try FoundationWebSocketTransport(endpoint: endpoint, maximumMessageBytes: limit)
      },
      currentDate: { now }
    )
    let configuration = try fixture.configuration(operationTimeout: .seconds(2))
    let original = try await BrowserSession.launch(configuration, dependencies: dependencies)
    let sessionCookie = try Cookie(name: "session", value: "s", domain: "example.test")
    let expired = try Cookie(
      name: "expired",
      value: "x",
      domain: "example.test",
      expires: now.addingTimeInterval(-1)
    )
    let active = try Cookie(
      name: "active",
      value: "a",
      domain: "example.test",
      expires: now.addingTimeInterval(60)
    )
    let checkpoint = try SessionCheckpoint(
      compatibility: configuration.compatibility,
      cookies: [sessionCookie, expired, active],
      createdAt: now.addingTimeInterval(-10)
    )

    do {
      let _: String = try await original.evaluate(
        "__fixture_delay__",
        timeout: .milliseconds(50)
      )
      XCTFail("expected timeout")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .operationTimedOut("Runtime.evaluate"))
    }

    let replacement = try await original.recover(from: checkpoint)
    do {
      let restored = try await replacement.cookies()
      XCTAssertEqual(Set(restored.map(\.name)), ["session", "active"])
      XCTAssertTrue(
        restored.contains(where: {
          CookieCodec.satisfiesPostcondition(observed: $0, expected: sessionCookie)
        })
      )
      XCTAssertTrue(
        restored.contains(where: {
          CookieCodec.satisfiesPostcondition(observed: $0, expected: active)
        })
      )
      XCTAssertFalse(restored.contains(where: { $0.name == "expired" }))
      let setCookieCalls = try fixture.requestRecords().filter {
        $0["method"] as? String == "Network.setCookies"
      }
      XCTAssertEqual(setCookieCalls.count, 1)
      let params = try XCTUnwrap(setCookieCalls.first?["params"] as? [String: Any])
      let sent = try XCTUnwrap(params["cookies"] as? [[String: Any]])
      XCTAssertEqual(Set(sent.compactMap { $0["name"] as? String }), ["session", "active"])
      await replacement.close()
    } catch {
      await replacement.close()
      throw error
    }
    let stopped = await fixture.waitUntilStopped(timeout: .seconds(3))
    XCTAssertTrue(stopped)
  }

  func testConcurrentCloseWinsOverSuspendedRecoveryWithoutResurrection() async throws {
    let fixture = try FixtureExecutable.make(delaySeconds: 1.0)
    defer { fixture.forceCleanup() }
    let gate = ReplacementLaunchGate()
    let dependencies = RuntimeDependencies(
      launchProcess: { launch in try await gate.launch(launch) },
      controlPlane: LoopbackEngineControlPlane(),
      makeTransport: { endpoint, limit in
        try FoundationWebSocketTransport(endpoint: endpoint, maximumMessageBytes: limit)
      }
    )
    let configuration = try fixture.configuration(operationTimeout: .seconds(2))
    let original = try await BrowserSession.launch(configuration, dependencies: dependencies)
    let checkpoint = try await original.checkpoint()

    do {
      let _: String = try await original.evaluate("__fixture_delay__", timeout: .milliseconds(50))
      XCTFail("expected timeout")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .operationTimedOut("Runtime.evaluate"))
    }

    let recovery = Task { try await original.recover(from: checkpoint) }
    let replacementWasRequested = await eventually {
      await gate.didStartReplacement()
    }
    XCTAssertTrue(replacementWasRequested)

    await original.close()
    await gate.releaseReplacement()
    do {
      let resurrected = try await recovery.value
      await resurrected.close()
      XCTFail("concurrent close must win over recovery")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .closed)
    }

    let snapshot = await original.snapshot()
    XCTAssertEqual(snapshot.phase, .closed)
    XCTAssertFalse(snapshot.failure?.contains("invalid state transition") == true)
    let stopped = await fixture.waitUntilStopped(timeout: .seconds(3))
    XCTAssertTrue(stopped)
  }

  func testConcurrentRecoveryCreatesOnlyOneReplacement() async throws {
    let fixture = try FixtureExecutable.make(delaySeconds: 1.0)
    defer { fixture.forceCleanup() }
    let gate = ReplacementLaunchGate()
    let dependencies = RuntimeDependencies(
      launchProcess: { launch in try await gate.launch(launch) },
      controlPlane: LoopbackEngineControlPlane(),
      makeTransport: { endpoint, limit in
        try FoundationWebSocketTransport(endpoint: endpoint, maximumMessageBytes: limit)
      }
    )
    let configuration = try fixture.configuration(operationTimeout: .seconds(2))
    let original = try await BrowserSession.launch(configuration, dependencies: dependencies)
    let checkpoint = try await original.checkpoint()
    do {
      let _: String = try await original.evaluate("__fixture_delay__", timeout: .milliseconds(50))
      XCTFail("expected timeout")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .operationTimedOut("Runtime.evaluate"))
    }

    let firstRecovery = Task { try await original.recover(from: checkpoint) }
    let replacementWasRequested = await eventually { await gate.didStartReplacement() }
    XCTAssertTrue(replacementWasRequested)
    do {
      _ = try await original.recover(from: checkpoint)
      XCTFail("expected duplicate recovery rejection")
    } catch {
      XCTAssertEqual(
        error as? ObscuraError,
        .invalidState("recovery is only valid for a quarantined session")
      )
    }
    let launchCount = await gate.replacementLaunchCount()
    XCTAssertEqual(launchCount, 2)

    await gate.releaseReplacement()
    let replacement = try await firstRecovery.value
    await replacement.close()
    let originalSnapshot = await original.snapshot()
    XCTAssertEqual(originalSnapshot.phase, .closed)
    let stopped = await fixture.waitUntilStopped(timeout: .seconds(3))
    XCTAssertTrue(stopped)
  }

  func testSessionSnapshotStreamEmitsExplicitTransitionsAndFinishes() async throws {
    let fixture = try FixtureExecutable.make()
    defer { fixture.forceCleanup() }
    let session = try await BrowserSession.launch(try fixture.configuration())
    let stream = await session.snapshots()
    let collector = Task { () -> [SessionPhase] in
      var phases: [SessionPhase] = []
      for await snapshot in stream { phases.append(snapshot.phase) }
      return phases
    }
    _ = try await session.navigate(to: dataURL("<title>Events</title>"))
    await session.close()
    let phases = await collector.value
    XCTAssertEqual(phases.first, .ready)
    XCTAssertTrue(phases.contains(.executing))
    XCTAssertTrue(phases.contains(.closing))
    XCTAssertEqual(phases.last, .closed)
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testMalformedDiscoveryFailsFastAndCleansChild() async throws {
    let fixture = try FixtureExecutable.make(mode: "malformed-discovery")
    defer { fixture.forceCleanup() }
    do {
      _ = try await BrowserSession.launch(try fixture.configuration())
      XCTFail("expected launch failure")
    } catch {
      guard case .controlPlane(let message) = error as? ObscuraError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("invalid discovery JSON"))
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testEarlyEngineExitIncludesDiagnosticsAndCleansChild() async throws {
    let fixture = try FixtureExecutable.make(mode: "early-exit")
    defer { fixture.forceCleanup() }
    do {
      _ = try await BrowserSession.launch(try fixture.configuration())
      XCTFail("expected engine exit")
    } catch {
      guard case .engineExited(let exit, let diagnostics) = error as? ObscuraError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(exit.exitCode, 72)
      XCTAssertTrue(diagnostics.contains("fixture early exit"))
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testStartupDeadlineStopsNonListeningChild() async throws {
    let fixture = try FixtureExecutable.make(mode: "no-listen")
    defer { fixture.forceCleanup() }
    do {
      _ = try await BrowserSession.launch(
        try fixture.configuration(startupTimeout: .milliseconds(150))
      )
      XCTFail("expected startup timeout")
    } catch {
      guard let obscura = error as? ObscuraError else {
        return XCTFail("unexpected error: \(error)")
      }
      switch obscura {
      case .startupTimedOut:
        break
      case .recoveryFailed(let primary, _):
        XCTAssertTrue(primary.contains("startup timed out"))
      default:
        XCTFail("unexpected error: \(obscura)")
      }
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testWrongResponseIDDuringStartupIsProtocolFailureAndNoOrphanRemains() async throws {
    let fixture = try FixtureExecutable.make(mode: "wrong-response-id")
    defer { fixture.forceCleanup() }
    do {
      _ = try await BrowserSession.launch(try fixture.configuration())
      XCTFail("expected protocol failure")
    } catch {
      guard case .protocolViolation(let message) = error as? ObscuraError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("unknown request id"))
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testRuntimeProcessExitQuarantinesSession() async throws {
    let fixture = try FixtureExecutable.make(mode: "exit-on-evaluate")
    defer { fixture.forceCleanup() }
    let session = try await BrowserSession.launch(try fixture.configuration())
    do {
      let _: Int = try await session.evaluate("1 + 2")
      XCTFail("expected runtime exit")
    } catch {
      let obscura = error as? ObscuraError
      XCTAssertTrue(
        obscura?.requiresQuarantine == true, "unexpected error: \(String(describing: obscura))")
    }
    let quarantined = await eventually { await session.snapshot().phase == .quarantined }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(quarantined)
    XCTAssertTrue(stopped)
    await session.close()
  }

  func testCloseInterruptsInFlightOperationWithoutInvariantFailure() async throws {
    let fixture = try FixtureExecutable.make(delaySeconds: 2.0)
    defer { fixture.forceCleanup() }
    let session = try await BrowserSession.launch(
      try fixture.configuration(operationTimeout: .seconds(5)))

    let operation = Task {
      try await session.evaluate("__fixture_delay__", as: String.self)
    }
    let dispatched = await eventually {
      (try? fixture.requestRecords().contains { $0["method"] as? String == "Runtime.evaluate" })
        == true
    }
    XCTAssertTrue(dispatched)

    await session.close()
    do {
      _ = try await operation.value
      XCTFail("expected close to interrupt operation")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .closed)
    }

    let snapshot = await session.snapshot()
    XCTAssertEqual(snapshot.phase, .closed)
    XCTAssertFalse(snapshot.failure?.contains("invalid state transition") == true)
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testStopFailureTriggersEmergencyTerminationAndRecordsFailure() async throws {
    let fixture = try FixtureExecutable.make()
    defer { fixture.forceCleanup() }
    let dependencies = RuntimeDependencies(
      launchProcess: { launch in
        StopFailingProcess(base: try await EngineProcess.launch(launch))
      },
      controlPlane: LoopbackEngineControlPlane(),
      makeTransport: { endpoint, limit in
        try FoundationWebSocketTransport(endpoint: endpoint, maximumMessageBytes: limit)
      }
    )
    let session = try await BrowserSession.launch(
      try fixture.configuration(),
      dependencies: dependencies
    )

    await session.close()

    let snapshot = await session.snapshot()
    XCTAssertEqual(snapshot.phase, .closed)
    XCTAssertTrue(snapshot.failure?.contains("synthetic stop failure") == true)
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testAbandonedSessionTerminatesChildProcess() async throws {
    let fixture = try FixtureExecutable.make()
    defer { fixture.forceCleanup() }

    var session: BrowserSession? = try await BrowserSession.launch(try fixture.configuration())
    XCTAssertNotNil(session)
    XCTAssertNotNil(fixture.recordedPID())
    session = nil

    let stopped = await fixture.waitUntilStopped(timeout: .seconds(3))
    XCTAssertTrue(
      stopped,
      "abandoning a live session must not leave the engine child running"
    )
  }

  func testCloseIsIdempotentAndLeavesNoChild() async throws {
    let fixture = try FixtureExecutable.make()
    defer { fixture.forceCleanup() }
    let session = try await BrowserSession.launch(try fixture.configuration())
    await session.close()
    await session.close()
    let snapshot = await session.snapshot()
    let stopped = await fixture.waitUntilStopped()
    XCTAssertEqual(snapshot.phase, .closed)
    XCTAssertTrue(stopped)
  }

  func testConcurrentCloseWaitsForTheSameShutdownBoundary() async throws {
    let fixture = try FixtureExecutable.make()
    defer { fixture.forceCleanup() }
    let gate = StopGate()
    let dependencies = RuntimeDependencies(
      launchProcess: { launch in
        GatedStopProcess(base: try await EngineProcess.launch(launch), gate: gate)
      },
      controlPlane: LoopbackEngineControlPlane(),
      makeTransport: { endpoint, limit in
        try FoundationWebSocketTransport(endpoint: endpoint, maximumMessageBytes: limit)
      }
    )
    let session = try await BrowserSession.launch(
      try fixture.configuration(),
      dependencies: dependencies
    )

    let first = Task { await session.close() }
    await gate.waitUntilEntered()
    let secondFinished = CompletionFlag()
    let second = Task {
      await session.close()
      await secondFinished.markCompleted()
    }
    try await Task.sleep(for: .milliseconds(50))
    let completedBeforeRelease = await secondFinished.completed
    XCTAssertFalse(
      completedBeforeRelease, "concurrent close returned before resource shutdown completed")

    await gate.release()
    await first.value
    await second.value
    let finalSnapshot = await session.snapshot()
    let stopped = await fixture.waitUntilStopped()
    XCTAssertEqual(finalSnapshot.phase, .closed)
    XCTAssertTrue(stopped)
  }

  private func withSession<T: Sendable>(
    _ fixture: FixtureExecutable,
    body: @escaping @Sendable (BrowserSession) async throws -> T
  ) async throws -> T {
    let session = try await BrowserSession.launch(try fixture.configuration())
    do {
      let value = try await body(session)
      await session.close()
      return value
    } catch {
      await session.close()
      throw error
    }
  }
}
