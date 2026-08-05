import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

internal enum EngineLocator {
  static func resolve(_ executable: EngineExecutable) throws -> URL {
    switch executable {
    case .explicit(let url):
      return try validateExplicit(url)
    case .chrome(let url):
      return try validateExplicit(url)
    case .vendored(let repositoryRoot):
      guard repositoryRoot.isFileURL else {
        throw ObscuraError.executableRejected("repository root must be a file URL")
      }
      let root = repositoryRoot.standardizedFileURL
      let vendorBoundary = root.appendingPathComponent("Vendor", isDirectory: true)
      let candidate =
        vendorBoundary
        .appendingPathComponent("Obscura", isDirectory: true)
        .appendingPathComponent("target", isDirectory: true)
        .appendingPathComponent("release", isDirectory: true)
        .appendingPathComponent("obscura", isDirectory: false)
      try rejectSymbolicLinksInsideVendor(from: vendorBoundary, through: candidate)
      return try validateRegularExecutable(candidate, followSymbolicLink: false)
    }
  }

  private static func validateExplicit(_ url: URL) throws -> URL {
    try validateRegularExecutable(url, followSymbolicLink: true)
  }

  private static func validateRegularExecutable(_ url: URL, followSymbolicLink: Bool) throws
    -> URL
  {
    guard url.isFileURL else {
      throw ObscuraError.executableRejected("engine path must be a file URL")
    }
    let standardized = url.standardizedFileURL
    let path = standardized.path
    guard !path.contains("\0") else {
      throw ObscuraError.executableRejected("engine path contains NUL")
    }
    var info = stat()
    let result = followSymbolicLink ? stat(path, &info) : lstat(path, &info)
    guard result == 0 else {
      throw ObscuraError.executableNotFound(path)
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      throw ObscuraError.executableRejected("engine is not a regular file: \(path)")
    }
    guard access(path, X_OK) == 0 else {
      throw ObscuraError.executableRejected("engine is not executable: \(path)")
    }
    return standardized
  }

  private static func rejectSymbolicLinksInsideVendor(from boundary: URL, through candidate: URL)
    throws
  {
    let boundary = boundary.standardizedFileURL
    let candidate = candidate.standardizedFileURL
    let prefix = boundary.path.hasSuffix("/") ? boundary.path : boundary.path + "/"
    guard candidate.path.hasPrefix(prefix) else {
      throw ObscuraError.executableRejected("vendored engine escaped Vendor boundary")
    }

    var cursor = boundary
    let relative = candidate.path.dropFirst(prefix.count)
    let components = relative.split(separator: "/", omittingEmptySubsequences: true)
    for (index, component) in components.enumerated() {
      cursor.appendPathComponent(String(component), isDirectory: index < components.count - 1)
      var info = stat()
      guard lstat(cursor.path, &info) == 0 else {
        throw ObscuraError.executableNotFound(cursor.path)
      }
      let kind = info.st_mode & S_IFMT
      if kind == S_IFLNK {
        throw ObscuraError.executableRejected(
          "vendored engine path must not contain a symbolic link: \(cursor.path)"
        )
      }
      if index < components.count - 1, kind != S_IFDIR {
        throw ObscuraError.executableRejected(
          "vendored engine parent is not a directory: \(cursor.path)"
        )
      }
    }
  }
}
