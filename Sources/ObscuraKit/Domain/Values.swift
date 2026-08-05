import Foundation

public struct SessionID: Sendable, Hashable, Codable, CustomStringConvertible {
  public let rawValue: UUID

  public init(_ rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue.uuidString }
}

public struct OperationID: Sendable, Hashable, Codable, CustomStringConvertible {
  public let rawValue: UInt64

  public init(_ rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public var description: String { String(rawValue) }
}

public enum EngineExecutable: Sendable, Equatable {
  case vendored(repositoryRoot: URL)
  /// An Obscura-compatible executable that accepts the Obscura `serve` contract.
  case explicit(URL)
  /// A Google Chrome or Chromium executable launched as an isolated headless browser.
  case chrome(executable: URL)
}

public enum NavigationWait: String, Sendable, Equatable, Codable {
  case domContentLoaded = "domcontentloaded"
  case load
  case networkIdle0 = "networkidle0"
  case networkIdle2 = "networkidle2"
}

public struct LaunchConfiguration: Sendable, Equatable {
  public let executable: EngineExecutable
  public let startupTimeout: Duration
  public let operationTimeout: Duration
  public let shutdownGrace: Duration
  public let diagnosticByteLimit: Int
  public let maximumMessageBytes: Int
  public let maximumQueuedOperations: Int
  public let proxy: String?
  public let userAgent: String?
  public let stealth: Bool
  public let allowPrivateNetwork: Bool

  /// Creates the simplest configuration for an isolated headless Google Chrome session.
  public static func chrome(executable: URL) throws -> LaunchConfiguration {
    try LaunchConfiguration(executable: .chrome(executable: executable))
  }

  public init(
    executable: EngineExecutable,
    startupTimeout: Duration = .seconds(15),
    operationTimeout: Duration = .seconds(30),
    shutdownGrace: Duration = .seconds(2),
    diagnosticByteLimit: Int = 64 * 1024,
    maximumMessageBytes: Int = 8 * 1024 * 1024,
    maximumQueuedOperations: Int = 64,
    proxy: String? = nil,
    userAgent: String? = nil,
    stealth: Bool = false,
    allowPrivateNetwork: Bool = false
  ) throws {
    guard startupTimeout > .zero else {
      throw ObscuraError.invalidConfiguration("startupTimeout must be positive")
    }
    guard operationTimeout > .zero else {
      throw ObscuraError.invalidConfiguration("operationTimeout must be positive")
    }
    guard shutdownGrace > .zero else {
      throw ObscuraError.invalidConfiguration("shutdownGrace must be positive")
    }
    guard (4 * 1024...4 * 1024 * 1024).contains(diagnosticByteLimit) else {
      throw ObscuraError.invalidConfiguration(
        "diagnosticByteLimit must be between 4 KiB and 4 MiB")
    }
    guard (64 * 1024...64 * 1024 * 1024).contains(maximumMessageBytes) else {
      throw ObscuraError.invalidConfiguration(
        "maximumMessageBytes must be between 64 KiB and 64 MiB")
    }
    guard (1...1_024).contains(maximumQueuedOperations) else {
      throw ObscuraError.invalidConfiguration(
        "maximumQueuedOperations must be between 1 and 1024")
    }
    try BoundaryValueValidator.validateProxy(proxy)
    try BoundaryValueValidator.validateUserAgent(userAgent)
    if case .chrome = executable, stealth {
      throw ObscuraError.invalidConfiguration(
        "stealth is only supported by the Obscura engine, not Chrome mode")
    }

    self.executable = executable
    self.startupTimeout = startupTimeout
    self.operationTimeout = operationTimeout
    self.shutdownGrace = shutdownGrace
    self.diagnosticByteLimit = diagnosticByteLimit
    self.maximumMessageBytes = maximumMessageBytes
    self.maximumQueuedOperations = maximumQueuedOperations
    self.proxy = proxy
    self.userAgent = userAgent
    self.stealth = stealth
    self.allowPrivateNetwork = allowPrivateNetwork
  }

  public var compatibility: SessionCompatibility {
    SessionCompatibility(
      validatedProxy: proxy,
      validatedUserAgent: userAgent,
      stealth: stealth,
      allowPrivateNetwork: allowPrivateNetwork
    )
  }
}

public struct SessionCompatibility: Sendable, Equatable, Codable {
  public let proxy: String?
  public let userAgent: String?
  public let stealth: Bool
  public let allowPrivateNetwork: Bool

  public init(
    proxy: String?,
    userAgent: String?,
    stealth: Bool,
    allowPrivateNetwork: Bool
  ) throws {
    try BoundaryValueValidator.validateProxy(proxy)
    try BoundaryValueValidator.validateUserAgent(userAgent)
    self.init(
      validatedProxy: proxy,
      validatedUserAgent: userAgent,
      stealth: stealth,
      allowPrivateNetwork: allowPrivateNetwork
    )
  }

  internal init(
    validatedProxy proxy: String?,
    validatedUserAgent userAgent: String?,
    stealth: Bool,
    allowPrivateNetwork: Bool
  ) {
    self.proxy = proxy
    self.userAgent = userAgent
    self.stealth = stealth
    self.allowPrivateNetwork = allowPrivateNetwork
  }

  private enum CodingKeys: String, CodingKey {
    case proxy
    case userAgent
    case stealth
    case allowPrivateNetwork
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      proxy: try container.decodeIfPresent(String.self, forKey: .proxy),
      userAgent: try container.decodeIfPresent(String.self, forKey: .userAgent),
      stealth: try container.decode(Bool.self, forKey: .stealth),
      allowPrivateNetwork: try container.decode(Bool.self, forKey: .allowPrivateNetwork)
    )
  }
}

public struct CSSSelector: Sendable, Hashable, Codable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty else {
      throw ObscuraError.invalidConfiguration("CSS selector is empty")
    }
    guard rawValue.utf8.count <= 4_096 else {
      throw ObscuraError.invalidConfiguration("CSS selector exceeds 4096 bytes")
    }
    guard !rawValue.contains("\0") else {
      throw ObscuraError.invalidConfiguration("CSS selector contains NUL")
    }
    guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
      throw ObscuraError.invalidConfiguration(
        "CSS selector has leading or trailing whitespace")
    }
    self.rawValue = rawValue
  }

  private enum CodingKeys: String, CodingKey {
    case rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(try container.decode(String.self, forKey: .rawValue))
  }

  public var description: String { rawValue }
}

public enum SameSite: String, Sendable, Codable, CaseIterable {
  case strict = "Strict"
  case lax = "Lax"
  case none = "None"
}

public struct Cookie: Sendable, Equatable, Codable, Hashable {
  public let name: String
  public let value: String
  public let domain: String
  public let path: String
  public let secure: Bool
  public let httpOnly: Bool
  public let sameSite: SameSite?
  public let expires: Date?

  public init(
    name: String,
    value: String,
    domain: String,
    path: String = "/",
    secure: Bool = false,
    httpOnly: Bool = false,
    sameSite: SameSite? = nil,
    expires: Date? = nil
  ) throws {
    guard !name.isEmpty, name.utf8.count <= 256,
      !BoundaryValueValidator.containsASCIIControl(name),
      !name.contains(";"), !name.contains(",")
    else {
      throw ObscuraError.invalidConfiguration("invalid cookie name")
    }
    guard value.utf8.count <= 16 * 1024,
      !BoundaryValueValidator.containsASCIIControl(value, allowingHorizontalTab: true)
    else {
      throw ObscuraError.invalidConfiguration("invalid cookie value")
    }
    guard !domain.isEmpty, domain.utf8.count <= 255,
      !domain.drop(while: { $0 == "." }).isEmpty,
      domain == domain.trimmingCharacters(in: .whitespacesAndNewlines),
      !BoundaryValueValidator.containsASCIIControl(domain),
      !domain.contains("/"), !domain.contains(":")
    else {
      throw ObscuraError.invalidConfiguration("invalid cookie domain")
    }
    guard path.hasPrefix("/"), path.utf8.count <= 2_048,
      !BoundaryValueValidator.containsASCIIControl(path)
    else {
      throw ObscuraError.invalidConfiguration("invalid cookie path")
    }
    if sameSite == SameSite.none, !secure {
      throw ObscuraError.invalidConfiguration("SameSite=None requires Secure")
    }
    if let expires, !expires.timeIntervalSince1970.isFinite {
      throw ObscuraError.invalidConfiguration("cookie expiry must be finite")
    }

    self.name = name
    self.value = value
    self.domain = domain
    self.path = path
    self.secure = secure
    self.httpOnly = httpOnly
    self.sameSite = sameSite
    self.expires = expires
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case value
    case domain
    case path
    case secure
    case httpOnly
    case sameSite
    case expires
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      name: try container.decode(String.self, forKey: .name),
      value: try container.decode(String.self, forKey: .value),
      domain: try container.decode(String.self, forKey: .domain),
      path: try container.decode(String.self, forKey: .path),
      secure: try container.decode(Bool.self, forKey: .secure),
      httpOnly: try container.decode(Bool.self, forKey: .httpOnly),
      sameSite: try container.decodeIfPresent(SameSite.self, forKey: .sameSite),
      expires: try container.decodeIfPresent(Date.self, forKey: .expires)
    )
  }
}

internal struct CookieIdentity: Sendable, Hashable {
  let name: String
  let domain: String
  let path: String
}

extension Cookie {
  var identity: CookieIdentity {
    CookieIdentity(
      name: name,
      domain: String(domain.drop(while: { $0 == "." })).lowercased(),
      path: path
    )
  }
}

public struct NavigationResult: Sendable, Equatable, Codable {
  public let url: URL
  public let frameID: String
  public let loaderID: String?
  public let generation: UInt64
}

public struct SessionCheckpoint: Sendable, Equatable, Codable {
  public static let maximumCookieCount = 1_024

  public let compatibility: SessionCompatibility
  public let cookies: [Cookie]
  public let createdAt: Date

  public init(
    compatibility: SessionCompatibility,
    cookies: [Cookie],
    createdAt: Date = Date()
  ) throws {
    try Self.validateCookies(cookies, context: "checkpoint")
    guard createdAt.timeIntervalSince1970.isFinite else {
      throw ObscuraError.invalidConfiguration("checkpoint creation date must be finite")
    }
    self.compatibility = compatibility
    self.cookies = cookies
    self.createdAt = createdAt
  }

  internal func restorableCookies(at date: Date) throws -> [Cookie] {
    guard date.timeIntervalSince1970.isFinite else {
      throw ObscuraError.invalidConfiguration("recovery date must be finite")
    }
    return cookies.filter { cookie in
      guard let expiry = cookie.expires else { return true }
      return expiry > date
    }
  }

  internal static func validateCookies(_ cookies: [Cookie], context: String) throws {
    guard cookies.count <= maximumCookieCount else {
      throw ObscuraError.resourceLimit(
        "\(context) exceeds \(maximumCookieCount) cookies")
    }
    var identities = Set<CookieIdentity>()
    identities.reserveCapacity(cookies.count)
    for cookie in cookies {
      guard identities.insert(cookie.identity).inserted else {
        throw ObscuraError.invalidConfiguration(
          "\(context) contains duplicate cookie identity "
            + "\(cookie.name) for \(cookie.domain)\(cookie.path)"
        )
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case compatibility
    case cookies
    case createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      compatibility: try container.decode(SessionCompatibility.self, forKey: .compatibility),
      cookies: try container.decode([Cookie].self, forKey: .cookies),
      createdAt: try container.decode(Date.self, forKey: .createdAt)
    )
  }
}

public enum SessionPhase: String, Sendable, Codable {
  case idle
  case starting
  case ready
  case executing
  case quarantined
  case recovering
  case closing
  case closed
}

public struct SessionSnapshot: Sendable, Equatable, Codable {
  public let id: SessionID
  public let phase: SessionPhase
  public let generation: UInt64
  public let activeOperation: OperationID?
  public let failure: String?
}

private enum BoundaryValueValidator {
  static func validateProxy(_ proxy: String?) throws {
    guard let proxy else { return }
    guard !proxy.isEmpty, proxy.utf8.count <= 4_096,
      proxy == proxy.trimmingCharacters(in: .whitespacesAndNewlines),
      !containsASCIIControl(proxy)
    else {
      throw ObscuraError.invalidConfiguration("proxy is empty, malformed, or too large")
    }
    guard let components = URLComponents(string: proxy),
      let scheme = components.scheme?.lowercased(),
      ["http", "https", "socks5", "socks5h"].contains(scheme),
      components.host != nil,
      components.fragment == nil
    else {
      throw ObscuraError.invalidConfiguration(
        "proxy must be an absolute http, https, socks5, or socks5h URL")
    }
  }

  static func validateUserAgent(_ userAgent: String?) throws {
    guard let userAgent else { return }
    guard !userAgent.isEmpty, userAgent.utf8.count <= 4_096,
      userAgent == userAgent.trimmingCharacters(in: .whitespacesAndNewlines),
      !containsASCIIControl(userAgent)
    else {
      throw ObscuraError.invalidConfiguration(
        "userAgent is empty, malformed, or exceeds 4096 bytes")
    }
  }

  static func containsASCIIControl(
    _ value: String,
    allowingHorizontalTab: Bool = false
  ) -> Bool {
    value.unicodeScalars.contains { scalar in
      let code = scalar.value
      if allowingHorizontalTab, code == 0x09 { return false }
      return code < 0x20 || code == 0x7F
    }
  }
}
