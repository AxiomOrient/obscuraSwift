import Foundation
import XCTest

@testable import ObscuraKit

final class ProtocolTests: XCTestCase, @unchecked Sendable {
  func testVendoredEncoderNeutralizesRawBrowserCloseWithoutChangingJSONMeaning() throws {
    let request = CDPRequest(
      id: 7,
      method: "Runtime.evaluate",
      params: .object([
        "expression": .string("'Browser.close'"), "cookie": .string("Browser.close"),
      ])
    )
    let text = try VendoredObscuraWireEncoder.encode(request, maximumBytes: 64 * 1024)
    XCTAssertFalse(text.contains("\"Browser.close\""))
    let decoded = try JSONDecoder().decode(CDPRequestProbe.self, from: Data(text.utf8))
    XCTAssertEqual(decoded.method, "Runtime.evaluate")
    XCTAssertEqual(decoded.params["expression"], .string("'Browser.close'"))
    XCTAssertEqual(decoded.params["cookie"], .string("Browser.close"))
    XCTAssertTrue(text.contains("Runtime.evaluate"))
    XCTAssertFalse(
      text.contains("\\u0052untime"), "unrelated uppercase characters must remain untouched")
  }

  func testVendoredEncoderDoesNotRewriteUnrelatedUppercaseB() throws {
    let request = CDPRequest(
      id: 9,
      method: "Browser.getVersion",
      params: .object(["value": .string("BOLD")])
    )
    let text = try VendoredObscuraWireEncoder.encode(request, maximumBytes: 64 * 1024)
    XCTAssertTrue(text.contains("Browser.getVersion"))
    XCTAssertTrue(text.contains("BOLD"))
    XCTAssertFalse(text.contains("\\u0042rowser.getVersion"))
    XCTAssertFalse(text.contains("\\u0042OLD"))
  }

  func testVendoredEncoderEnforcesExpandedWireLimit() throws {
    let request = CDPRequest(id: 1, method: "BBBB", params: .object([:]))
    XCTAssertThrowsError(try VendoredObscuraWireEncoder.encode(request, maximumBytes: 20))
  }

  func testEvaluationCodecDecodesTypedValueAndErrors() throws {
    let success = JSONValue.object([
      "result": .object([
        "value": .object(["ok": .bool(true), "json": .string("{\"answer\":42}")])
      ])
    ])
    struct Value: Decodable, Equatable { let answer: Int }
    XCTAssertEqual(try EvaluationCodec.decode(success, as: Value.self), Value(answer: 42))

    let exception = JSONValue.object([
      "result": .object([
        "value": .object([
          "ok": .bool(false),
          "kind": .string("exception"),
          "message": .string("boom"),
        ])
      ])
    ])
    XCTAssertThrowsError(try EvaluationCodec.decode(exception, as: Value.self)) { error in
      XCTAssertEqual(error as? ObscuraError, .javaScript("boom"))
    }
  }

  func testEvaluationExpressionOwnsSourceAsJSONString() throws {
    let source = "\"; throw new Error('x') //\nBrowser.close"
    let expression = try EvaluationCodec.expression(for: source)
    XCTAssertTrue(expression.contains("const __obscuraKitSource ="))
    XCTAssertFalse(expression.contains("__obscuraKitMarker"))
    XCTAssertTrue(expression.contains("kind: \"unsupported\""))
    XCTAssertTrue(expression.contains("not JSON-serializable"))
    let match = expression.range(of: "Browser.close")
    XCTAssertNotNil(match)
  }

  func testInvalidCallDoesNotSendOrConsumeRequestIdentifier() async throws {
    let transport = ScriptedWebSocketTransport(behavior: .success(.object(["ok": .bool(true)])))
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()

    do {
      _ = try await connection.call("Runtime.evaluate", timeout: .zero)
      XCTFail("expected invalid timeout")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .invalidConfiguration("CDP timeout must be positive"))
    }
    let framesBeforeValidCall = await transport.sentFrames()
    XCTAssertTrue(framesBeforeValidCall.isEmpty)

    _ = try await connection.call("Runtime.evaluate", timeout: .seconds(1))
    let frames = await transport.sentFrames()
    XCTAssertEqual(frames.count, 1)
    let decoded = try JSONDecoder().decode(CDPRequestProbe.self, from: Data(frames[0].utf8))
    XCTAssertEqual(decoded.id, 1)
    await connection.close()
  }

  func testCookieCodecRejectsMalformedWireValues() throws {
    let malformedSameSite = JSONValue.object([
      "cookies": .array([
        .object([
          "name": .string("sid"),
          "value": .string("x"),
          "domain": .string("example.test"),
          "path": .string("/"),
          "secure": .bool(true),
          "httpOnly": .bool(false),
          "sameSite": .string("Unknown"),
          "expires": .number(-1),
        ])
      ])
    ])
    XCTAssertThrowsError(try CookieCodec.decode(malformedSameSite))

    let wrongBoolean = JSONValue.object([
      "cookies": .array([
        .object([
          "name": .string("sid"),
          "value": .string("x"),
          "domain": .string("example.test"),
          "path": .string("/"),
          "secure": .string("false"),
          "httpOnly": .bool(false),
        ])
      ])
    ])
    XCTAssertThrowsError(try CookieCodec.decode(wrongBoolean))
  }

  func testCookiePostconditionChecksSecurityAndExpirySemantics() throws {
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    let expected = try Cookie(
      name: "sid",
      value: "x",
      domain: ".Example.Test",
      secure: true,
      httpOnly: true,
      sameSite: SameSite.none,
      expires: expiry
    )
    let equivalent = try Cookie(
      name: "sid",
      value: "x",
      domain: "example.test",
      secure: true,
      httpOnly: true,
      sameSite: SameSite.none,
      expires: expiry.addingTimeInterval(0.5)
    )
    let weakened = try Cookie(
      name: "sid",
      value: "x",
      domain: "example.test",
      secure: true,
      httpOnly: false,
      sameSite: SameSite.none,
      expires: expiry
    )
    XCTAssertTrue(CookieCodec.satisfiesPostcondition(observed: equivalent, expected: expected))
    XCTAssertFalse(CookieCodec.satisfiesPostcondition(observed: weakened, expected: expected))
  }

  func testCDPConnectionCorrelatesSuccessfulResponse() async throws {
    let transport = ScriptedWebSocketTransport(behavior: .success(.object(["value": .number(42)])))
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()
    let response = try await connection.call("Runtime.evaluate", timeout: .seconds(1))
    XCTAssertEqual(response, .object(["value": .number(42)]))
    let sentCount = await transport.sentFrames().count
    XCTAssertEqual(sentCount, 1)
    await connection.close()
  }

  func testCDPConnectionPropagatesCDPErrorWithoutTerminatingConnection() async throws {
    let transport = ScriptedWebSocketTransport(
      behavior: .cdpError(code: -32601, message: "unsupported"))
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()
    do {
      _ = try await connection.call("Nope.method", timeout: .seconds(1))
      XCTFail("expected CDP error")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .cdp(code: -32601, message: "unsupported"))
    }
    do {
      _ = try await connection.call("Nope.method", timeout: .seconds(1))
      XCTFail("expected second CDP error")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .cdp(code: -32601, message: "unsupported"))
    }
    await connection.close()
  }

  func testUnknownResponseIDIsTerminalProtocolViolation() async throws {
    let transport = ScriptedWebSocketTransport(behavior: .wrongResponseID)
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()
    do {
      _ = try await connection.call("Page.enable", timeout: .seconds(1))
      XCTFail("expected protocol failure")
    } catch {
      guard case .protocolViolation(let message) = error as? ObscuraError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("unknown request id"))
    }
    guard case .protocolViolation = await connection.waitForTermination() else {
      return XCTFail("connection did not become terminal")
    }
  }

  func testResponseSessionMustMatchRequest() async throws {
    let transport = ScriptedWebSocketTransport(behavior: .sessionScopedResponse)
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()
    do {
      _ = try await connection.call("Page.enable", timeout: .seconds(1))
      XCTFail("expected protocol failure")
    } catch {
      guard case .protocolViolation(let message) = error as? ObscuraError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("session does not match"))
    }
  }

  func testUnexpectedSessionEventIsTerminal() async throws {
    let transport = ScriptedWebSocketTransport(behavior: .sessionScopedEvent)
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()
    await assertThrowsAsyncError(
      try await connection.call("Page.enable", timeout: .seconds(1)))
    guard case .protocolViolation = await connection.waitForTermination() else {
      return XCTFail("connection did not reject session-scoped event")
    }
  }

  func testPageCallUsesEstablishedSessionAndAcceptsMatchingResponse() async throws {
    let transport = ScriptedWebSocketTransport(behavior: .matchingRequestSession)
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()
    try await connection.adoptPageSession("page-1-session")

    _ = try await connection.callPage("Page.enable", timeout: .seconds(1))
    let frames = await transport.sentFrames()
    let request = try JSONDecoder().decode(
      CDPRequestProbe.self, from: Data(try XCTUnwrap(frames.first).utf8))
    XCTAssertEqual(request.sessionID, "page-1-session")
    await connection.close()
  }

  func testVendoredBootstrapCreatesExactlyOneScopedPageSession() async throws {
    let transport = ScriptedWebSocketTransport(behavior: .vendoredBootstrap)
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()
    let endpoint = EngineEndpoint(
      browserWebSocketURL: try XCTUnwrap(URL(string: "ws://127.0.0.1:9222/devtools/browser")),
      pageTargetID: "page-1",
      browserVersion: "Chrome/145.0.0.0",
      protocolVersion: "1.3"
    )

    try await VendoredObscuraSessionBootstrap.initialize(
      connection: connection,
      endpoint: endpoint,
      timeout: .seconds(1)
    )

    let frames = await transport.sentFrames()
    let requests = try frames.map {
      try JSONDecoder().decode(CDPRequestProbe.self, from: Data($0.utf8))
    }
    XCTAssertEqual(
      requests.map(\.method),
      [
        "Target.createTarget",
        "Target.attachToTarget",
        "Page.enable",
        "Runtime.enable",
        "Network.enable",
        "Browser.getVersion",
      ]
    )
    XCTAssertEqual(requests[0].params["url"], .string("about:blank"))
    XCTAssertEqual(requests[1].params["targetId"], .string("page-1"))
    XCTAssertEqual(requests[1].params["flatten"], .bool(true))
    XCTAssertEqual(requests[0].sessionID, nil)
    XCTAssertEqual(requests[1].sessionID, nil)
    XCTAssertEqual(requests[2].sessionID, "page-1-session")
    XCTAssertEqual(requests[3].sessionID, "page-1-session")
    XCTAssertEqual(requests[4].sessionID, "page-1-session")
    XCTAssertEqual(requests[5].sessionID, nil)
    await connection.close()
  }

  func testInvalidEventParamsAreRejectedButValidEventsAreDropped() async throws {
    let invalidTransport = ScriptedWebSocketTransport(behavior: .invalidEventParams)
    let invalidConnection = CDPConnection(
      transport: invalidTransport, maximumMessageBytes: 64 * 1024)
    try await invalidConnection.connect()
    await assertThrowsAsyncError(
      try await invalidConnection.call("Page.enable", timeout: .seconds(1)))
    guard case .protocolViolation = await invalidConnection.waitForTermination() else {
      return XCTFail("connection did not reject malformed event params")
    }

    let validTransport = ScriptedWebSocketTransport(behavior: .validEventThenSuccess)
    let validConnection = CDPConnection(transport: validTransport, maximumMessageBytes: 64 * 1024)
    try await validConnection.connect()
    let value = try await validConnection.call("Page.enable", timeout: .seconds(1))
    XCTAssertEqual(value, .object([:]))
    await validConnection.close()
  }

  func testMalformedResponseIsTerminal() async throws {
    let transport = ScriptedWebSocketTransport(behavior: .malformed)
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()
    await assertThrowsAsyncError(try await connection.call("Page.enable", timeout: .seconds(1)))
    guard case .protocolViolation = await connection.waitForTermination() else {
      return XCTFail("connection did not report protocol violation")
    }
  }

  func testTimeoutAfterSendTerminatesConnectionWithoutHanging() async throws {
    let transport = ScriptedWebSocketTransport(behavior: .noResponse)
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()
    let started = ContinuousClock().now
    do {
      _ = try await connection.call("Runtime.evaluate", timeout: .milliseconds(40))
      XCTFail("expected timeout")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .operationTimedOut("Runtime.evaluate"))
    }
    XCTAssertLessThan(started.duration(to: ContinuousClock().now), .seconds(1))
    let termination = await connection.waitForTermination()
    XCTAssertEqual(termination, .operationTimedOut("Runtime.evaluate"))
  }

  func testCancellationAfterSendTerminatesConnection() async throws {
    let transport = ScriptedWebSocketTransport(behavior: .noResponse)
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()
    let task = Task { try await connection.call("Runtime.evaluate", timeout: .seconds(10)) }
    let wasSent = await eventually { await transport.sentFrames().count == 1 }
    XCTAssertTrue(wasSent)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .cancelled("Runtime.evaluate"))
    }
    let termination = await connection.waitForTermination()
    XCTAssertEqual(termination, .cancelled("Runtime.evaluate"))
  }

  func testCancellationDuringSendTerminatesWithoutRetryingTheFrame() async throws {
    let gate = StopGate()
    let transport = GatedSendWebSocketTransport(gate: gate)
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()
    let task = Task { try await connection.call("Runtime.evaluate", timeout: .seconds(10)) }
    defer {
      Task {
        await gate.release()
        await connection.close()
      }
    }

    _ = try await withTimeout(.seconds(1)) { await gate.waitUntilEntered() }
    let sentBeforeCancellation = await transport.sentFrames().count
    XCTAssertEqual(sentBeforeCancellation, 1)

    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch {
      XCTAssertEqual(error as? ObscuraError, .cancelled("Runtime.evaluate"))
    }
    let termination = try await withTimeout(.seconds(1)) {
      await connection.waitForTermination()
    }
    XCTAssertEqual(termination, .cancelled("Runtime.evaluate"))
    let sentAfterCancellation = await transport.sentFrames().count
    XCTAssertEqual(sentAfterCancellation, 1)
  }

  func testCloseIsIdempotentAndCompletesPendingCall() async throws {
    let transport = ScriptedWebSocketTransport(behavior: .noResponse)
    let connection = CDPConnection(transport: transport, maximumMessageBytes: 64 * 1024)
    try await connection.connect()
    let task = Task { try await connection.call("Page.enable", timeout: .seconds(10)) }
    let wasSent = await eventually { await transport.sentFrames().count == 1 }
    XCTAssertTrue(wasSent)
    await connection.close()
    await connection.close()
    await assertThrowsAsyncError(try await task.value)
    let termination = await connection.waitForTermination()
    XCTAssertNil(termination)
  }
}

private struct CDPRequestProbe: Decodable {
  let id: Int
  let method: String
  let params: [String: JSONValue]
  let sessionID: String?

  enum CodingKeys: String, CodingKey {
    case id, method, params
    case sessionID = "sessionId"
  }
}

extension XCTestCase {
  fileprivate func assertThrowsAsyncError<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await expression()
      XCTFail("expected error", file: file, line: line)
    } catch {}
  }
}
