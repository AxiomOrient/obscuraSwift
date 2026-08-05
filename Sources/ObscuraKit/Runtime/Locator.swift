import Foundation

public struct Locator: Sendable {
  private let session: BrowserSession
  public let selector: CSSSelector

  internal init(session: BrowserSession, selector: CSSSelector) {
    self.session = session
    self.selector = selector
  }

  public func textContent(timeout: Duration? = nil) async throws -> String? {
    try await session.locatorText(selector, timeout: timeout)
  }

  public func attribute(_ name: String, timeout: Duration? = nil) async throws -> String? {
    try await session.locatorAttribute(selector, name: name, timeout: timeout)
  }

  public func invokeDOMClick(timeout: Duration? = nil) async throws {
    try await session.locatorClick(selector, timeout: timeout)
  }

  public func setValue(_ value: String, timeout: Duration? = nil) async throws {
    try await session.locatorSetValue(selector, value: value, timeout: timeout)
  }
}
