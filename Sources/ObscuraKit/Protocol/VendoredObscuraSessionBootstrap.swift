import Foundation

/// Stateless adapter for the vendored engine's browser-level CDP handshake.
///
/// `BrowserSession` owns connection lifetime and reducer events. This adapter
/// owns only the vendor-specific request sequence that turns a connected
/// browser WebSocket into one usable page session.
internal enum VendoredObscuraSessionBootstrap {
  static func initialize(
    connection: CDPConnection,
    endpoint: EngineEndpoint,
    timeout: Duration
  ) async throws {
    let targetID = try await createPageTarget(connection: connection, timeout: timeout)
    guard endpoint.engineFlavor != .obscura || targetID == endpoint.pageTargetID else {
      throw ObscuraError.protocolViolation(
        "Target.createTarget response is missing the discovered page target")
    }

    let sessionID = try await attach(
      connection: connection,
      targetID: targetID,
      timeout: timeout
    )
    try await connection.adoptPageSession(sessionID)

    for method in ["Page.enable", "Runtime.enable", "Network.enable"] {
      _ = try await connection.callPage(method, timeout: timeout)
    }
    _ = try await connection.call("Browser.getVersion", timeout: timeout)
  }

  private static func createPageTarget(
    connection: CDPConnection,
    timeout: Duration
  ) async throws -> String {
    let response = try await connection.call(
      "Target.createTarget",
      params: .object(["url": .string("about:blank")]),
      timeout: timeout
    )
    guard case .object(let object) = response,
      let targetID = object["targetId"]?.stringValue
    else {
      throw ObscuraError.protocolViolation("Target.createTarget response is missing targetId")
    }
    return targetID
  }

  private static func attach(
    connection: CDPConnection,
    targetID: String,
    timeout: Duration
  ) async throws -> String {
    let response = try await connection.call(
      "Target.attachToTarget",
      params: .object([
        "targetId": .string(targetID),
        "flatten": .bool(true),
      ]),
      timeout: timeout
    )
    guard case .object(let object) = response,
      let sessionID = object["sessionId"]?.stringValue
    else {
      throw ObscuraError.protocolViolation("Target.attachToTarget response is missing sessionId")
    }
    return sessionID
  }
}
