import Foundation

internal enum TimeoutSentinel: Error, Sendable {
  case elapsed
}

/// A monotonic deadline shared by every side effect that belongs to one
/// logical session operation. Each adapter call receives only the remaining
/// budget, so multi-step operations cannot accidentally multiply their
/// configured timeout and no second timeout task races the protocol timeout.
internal struct OperationDeadline: Sendable {
  private let instant: ContinuousClock.Instant

  init(timeout: Duration) {
    self.instant = ContinuousClock().now.advanced(by: timeout)
  }

  func remaining(for operation: String) throws -> Duration {
    let remaining = ContinuousClock().now.duration(to: instant)
    guard remaining > .zero else {
      throw ObscuraError.operationTimedOut(operation)
    }
    return remaining
  }
}

internal func withTimeout<T: Sendable>(
  _ duration: Duration,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw TimeoutSentinel.elapsed
    }
    guard let first = try await group.next() else {
      throw TimeoutSentinel.elapsed
    }
    group.cancelAll()
    return first
  }
}

extension Duration {
  var wholeMilliseconds: Int64 {
    let components = self.components
    let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
    let attoseconds = components.attoseconds / 1_000_000_000_000_000
    let sum = seconds.partialValue.addingReportingOverflow(attoseconds)
    if seconds.overflow || sum.overflow {
      return self < .zero ? Int64.min : Int64.max
    }
    return sum.partialValue
  }
}
