import Foundation

/// A single chronological tail buffer for child-process diagnostics.
///
/// `limit` applies to the complete retained representation, not independently
/// to stdout and stderr. This makes the configured memory bound exact even when
/// both streams are flooded concurrently.
internal actor BoundedDiagnosticBuffer {
  private enum Stream: Equatable {
    case stdout
    case stderr

    var marker: Data {
      switch self {
      case .stdout: Data("\n[stdout]\n".utf8)
      case .stderr: Data("\n[stderr]\n".utf8)
      }
    }
  }

  private let limit: Int
  private var bytes = Data()
  private var lastStream: Stream?

  init(limit: Int) {
    self.limit = limit
  }

  func appendStdout(_ data: Data) {
    append(data, stream: .stdout)
  }

  func appendStderr(_ data: Data) {
    append(data, stream: .stderr)
  }

  func snapshot() -> String {
    String(decoding: bytes, as: UTF8.self)
  }

  private func append(_ data: Data, stream: Stream) {
    guard !data.isEmpty else { return }
    if lastStream != stream {
      bytes.append(stream.marker)
      lastStream = stream
    }
    bytes.append(data)
    if bytes.count > limit {
      bytes.removeFirst(bytes.count - limit)
    }
  }
}
