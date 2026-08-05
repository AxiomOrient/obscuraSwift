import Foundation

internal enum EvaluationCodec {
  static func expression(for source: String) throws -> String {
    guard source.utf8.count <= 1_048_576 else {
      throw ObscuraError.resourceLimit("JavaScript source exceeds 1 MiB")
    }
    let sourceLiteral = try jsonString(source)
    return """
      (async function () {
        const __obscuraKitSource = \(sourceLiteral);
        let __obscuraKitValue;
        try {
          __obscuraKitValue = await (0, eval)(__obscuraKitSource);
        } catch (__obscuraKitError) {
          return {
            ok: false,
            kind: "exception",
            message: String(__obscuraKitError && (__obscuraKitError.stack || __obscuraKitError.message) || __obscuraKitError)
          };
        }
        if (__obscuraKitValue === undefined) {
          return { ok: false, kind: "unsupported", message: "JavaScript returned undefined" };
        }
        try {
          const __obscuraKitJSON = JSON.stringify(__obscuraKitValue);
          if (__obscuraKitJSON === undefined) {
            return { ok: false, kind: "unsupported", message: "JavaScript result is not JSON-serializable" };
          }
          return { ok: true, json: __obscuraKitJSON };
        } catch (__obscuraKitError) {
          return {
            ok: false,
            kind: "unsupported",
            message: "JavaScript result is not JSON-serializable: "
              + String(__obscuraKitError && (__obscuraKitError.message || __obscuraKitError) || __obscuraKitError)
          };
        }
      })()
      """
  }

  static func decode<T: Decodable & Sendable>(_ response: JSONValue, as type: T.Type) throws -> T {
    guard case .object(let root) = response,
      case .object(let remote)? = root["result"],
      case .object(let envelope)? = remote["value"],
      case .bool(let ok)? = envelope["ok"]
    else {
      throw ObscuraError.protocolViolation(
        "Runtime.evaluate response does not contain the owned envelope")
    }
    if ok {
      guard case .string(let json)? = envelope["json"] else {
        throw ObscuraError.protocolViolation("successful evaluation envelope is missing JSON")
      }
      do {
        return try JSONDecoder().decode(type, from: Data(json.utf8))
      } catch {
        throw ObscuraError.unsupportedJavaScriptResult("typed decode failed: \(error)")
      }
    }
    let kind = envelope["kind"]?.stringValue ?? "unknown"
    let message = envelope["message"]?.stringValue ?? "evaluation failed without a message"
    if kind == "exception" { throw ObscuraError.javaScript(message) }
    throw ObscuraError.unsupportedJavaScriptResult(message)
  }

  private static func jsonString(_ value: String) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let result = String(data: data, encoding: .utf8) else {
      throw ObscuraError.protocolViolation("failed to encode JavaScript source")
    }
    return result
  }
}
