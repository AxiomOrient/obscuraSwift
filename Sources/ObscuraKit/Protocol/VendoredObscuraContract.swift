import Foundation

internal enum VendoredObscuraWireEncoder {
  private static let unsafeSentinel = Data("\"Browser.close\"".utf8)
  private static let safeSentinel = Data("\"\\u0042rowser.close\"".utf8)

  static func encode<T: Encodable>(_ value: T, maximumBytes: Int) throws -> String {
    var encoded = try JSONEncoder().encode(value)

    // The vendored server closes a connection when the raw frame contains the
    // exact bytes `"Browser.close"`, even when those bytes occur inside an
    // unrelated JavaScript expression or value. Preserve normal JSON output
    // and neutralize only that sentinel by escaping its leading `B`. Escaping
    // every uppercase B would alter wire size unpredictably and needlessly
    // rewrite unrelated payloads.
    while let range = encoded.range(of: unsafeSentinel) {
      encoded.replaceSubrange(range, with: safeSentinel)
      if encoded.count > maximumBytes {
        throw ObscuraError.resourceLimit("encoded CDP frame exceeds configured limit")
      }
    }

    guard encoded.count <= maximumBytes else {
      throw ObscuraError.resourceLimit("encoded CDP frame exceeds configured limit")
    }
    guard encoded.range(of: unsafeSentinel) == nil else {
      throw ObscuraError.protocolViolation("vendored Browser.close sentinel remained in data")
    }
    guard let text = String(data: encoded, encoding: .utf8) else {
      throw ObscuraError.protocolViolation("encoded CDP frame is not UTF-8")
    }
    return text
  }
}
