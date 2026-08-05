import Foundation

internal enum EngineFlavor: Sendable, Equatable {
  case obscura
  case chrome
}

extension EngineExecutable {
  internal var engineFlavor: EngineFlavor {
    switch self {
    case .vendored, .explicit:
      .obscura
    case .chrome:
      .chrome
    }
  }
}
