import CObscuraProcess
import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

internal struct EngineProcessLaunch: Sendable {
  let executable: URL
  let arguments: [String]
  let environment: [String: String]
  let shutdownGrace: Duration
  let diagnosticByteLimit: Int
}

internal actor EngineProcess {
  private typealias ExitResult = Result<EngineExit, ObscuraError>

  let pid: Int32
  private let shutdownGrace: Duration
  private let diagnostics: BoundedDiagnosticBuffer
  private var exitResult: ExitResult?
  private var exitWaiters: [UUID: CheckedContinuation<EngineExit, Error>] = [:]
  private var stopTask: Task<EngineExit, Error>?
  private var stdoutTask: Task<Void, Never>?
  private var stderrTask: Task<Void, Never>?
  private var waitTask: Task<Void, Never>?

  private init(pid: Int32, shutdownGrace: Duration, diagnostics: BoundedDiagnosticBuffer) {
    self.pid = pid
    self.shutdownGrace = shutdownGrace
    self.diagnostics = diagnostics
  }

  deinit {
    // EngineProcess can be used directly by adapters and tests, independently
    // of BrowserSession. Dropping the last owner must not orphan its process
    // group. The detached wait task remains responsible for waitpid/reaping.
    _ = obscura_signal_process_group(pid, SIGKILL)
    stdoutTask?.cancel()
    stderrTask?.cancel()
  }

  static func launch(_ launch: EngineProcessLaunch) async throws -> EngineProcess {
    let strings = [launch.executable.path] + launch.arguments
    let environment = launch.environment.keys.sorted().map { "\($0)=\(launch.environment[$0]!)" }
    var result = obscura_spawn_result(pid: -1, stdout_fd: -1, stderr_fd: -1, error_number: 0)

    let error: Int32 = try withMutableCStringArray(strings) { argv in
      try withMutableCStringArray(environment) { envp in
        launch.executable.path.withCString { executable in
          obscura_spawn_process(executable, argv, envp, &result)
        }
      }
    }
    guard error == 0, result.pid > 0 else {
      throw ObscuraError.processLaunchFailed(
        errno: error == 0 ? result.error_number : error,
        message: String(cString: strerror(error == 0 ? result.error_number : error))
      )
    }

    let diagnosticBuffer = BoundedDiagnosticBuffer(limit: launch.diagnosticByteLimit)
    let process = EngineProcess(
      pid: result.pid, shutdownGrace: launch.shutdownGrace, diagnostics: diagnosticBuffer)
    await process.startMonitoring(stdoutFD: result.stdout_fd, stderrFD: result.stderr_fd)
    return process
  }

  func waitForExit() async throws -> EngineExit {
    if let exitResult { return try exitResult.get() }
    let waiterID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else if let exitResult {
          continuation.resume(with: exitResult)
        } else {
          exitWaiters[waiterID] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelExitWaiter(waiterID) }
    }
  }

  func isRunning() -> Bool {
    exitResult == nil && obscura_process_is_alive(pid) == 1
  }

  func diagnosticSnapshot() async -> String {
    await diagnostics.snapshot()
  }

  nonisolated func terminateImmediately() {
    _ = obscura_signal_process_group(pid, SIGKILL)
  }

  func stop() async throws -> EngineExit {
    if let exitResult { return try exitResult.get() }
    if let stopTask { return try await stopTask.value }
    let task = Task { try await self.performStop() }
    stopTask = task
    do {
      let value = try await task.value
      stopTask = nil
      return value
    } catch {
      stopTask = nil
      throw error
    }
  }

  private func startMonitoring(stdoutFD: Int32, stderrFD: Int32) {
    let diagnostics = self.diagnostics
    stdoutTask = Task.detached(priority: .utility) {
      await Self.drain(fd: stdoutFD) { data in await diagnostics.appendStdout(data) }
    }
    stderrTask = Task.detached(priority: .utility) {
      await Self.drain(fd: stderrFD) { data in await diagnostics.appendStderr(data) }
    }
    let pid = self.pid
    waitTask = Task.detached(priority: .utility) { [weak self] in
      var rawStatus: Int32 = 0
      let waitError = obscura_wait_process(pid, &rawStatus)
      let result: ExitResult
      if waitError == 0 {
        if obscura_status_exited(rawStatus) == 1 {
          result = .success(EngineExit(exitCode: obscura_status_exit_code(rawStatus), signal: nil))
        } else if obscura_status_signaled(rawStatus) == 1 {
          result = .success(
            EngineExit(exitCode: nil, signal: obscura_status_term_signal(rawStatus)))
        } else {
          result = .failure(.protocolViolation("unrecognized process wait status \(rawStatus)"))
        }
      } else {
        result = .failure(.processLaunchFailed(errno: waitError, message: "waitpid failed"))
      }
      await self?.finishExit(result)
    }
  }

  private func finishExit(_ result: ExitResult) async {
    // The process leader may exit while descendants still retain stdout/stderr.
    // Terminate the remaining process group before waiting for pipe EOF so exit
    // observation cannot deadlock on inherited writer descriptors.
    _ = obscura_signal_process_group(pid, SIGKILL)
    let stdoutTask = self.stdoutTask
    let stderrTask = self.stderrTask
    stdoutTask?.cancel()
    stderrTask?.cancel()
    await stdoutTask?.value
    await stderrTask?.value
    recordExit(result)
  }

  private func performStop() async throws -> EngineExit {
    if let exitResult { return try exitResult.get() }
    let termError = obscura_signal_process_group(pid, SIGTERM)
    if termError != 0, termError != ESRCH {
      throw ObscuraError.processLaunchFailed(errno: termError, message: "failed to send SIGTERM")
    }
    do {
      return try await withTimeout(shutdownGrace) { try await self.waitForExit() }
    } catch TimeoutSentinel.elapsed {
      let killError = obscura_signal_process_group(pid, SIGKILL)
      if killError != 0, killError != ESRCH {
        throw ObscuraError.processLaunchFailed(errno: killError, message: "failed to send SIGKILL")
      }
      return try await waitForExit()
    }
  }

  private func recordExit(_ result: ExitResult) {
    guard exitResult == nil else { return }
    exitResult = result
    let waiters = exitWaiters.values
    exitWaiters.removeAll(keepingCapacity: false)
    for continuation in waiters {
      continuation.resume(with: result)
    }
  }

  private func cancelExitWaiter(_ id: UUID) {
    guard let continuation = exitWaiters.removeValue(forKey: id) else { return }
    continuation.resume(throwing: CancellationError())
  }

  private static func drain(
    fd: Int32,
    append: @escaping @Sendable (Data) async -> Void
  ) async {
    guard fd >= 0 else { return }
    defer { _ = close(fd) }

    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 {
      _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    var descriptor = pollfd(
      fd: fd,
      events: Int16(POLLIN | POLLHUP | POLLERR),
      revents: 0
    )
    var buffer = [UInt8](repeating: 0, count: 8_192)

    while true {
      while true {
        let count = buffer.withUnsafeMutableBytes { storage in
          read(fd, storage.baseAddress, storage.count)
        }
        if count > 0 {
          await append(Data(buffer.prefix(Int(count))))
          continue
        }
        if count == 0 {
          return
        }
        if errno == EINTR {
          continue
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          break
        }
        return
      }

      // Cancellation is observed only after draining bytes already available.
      if Task.isCancelled {
        return
      }

      descriptor.revents = 0
      let pollResult = poll(&descriptor, 1, 100)
      if pollResult > 0 || pollResult == 0 {
        continue
      }
      if errno != EINTR {
        return
      }
    }
  }
}

private func withMutableCStringArray<T>(
  _ strings: [String],
  _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
) throws -> T {
  var pointers: [UnsafeMutablePointer<CChar>?] = []
  pointers.reserveCapacity(strings.count + 1)
  for string in strings {
    guard !string.contains("\0") else {
      throw ObscuraError.invalidConfiguration("process argument contains NUL")
    }
    guard let pointer = strdup(string) else {
      throw ObscuraError.processLaunchFailed(
        errno: ENOMEM, message: "failed to allocate process argument")
    }
    pointers.append(pointer)
  }
  pointers.append(nil)
  defer {
    for pointer in pointers where pointer != nil {
      free(pointer)
    }
  }
  return try pointers.withUnsafeMutableBufferPointer { buffer in
    try body(buffer.baseAddress!)
  }
}

internal enum EngineEnvironment {
  static func sanitized(
    from environment: [String: String] = ProcessInfo.processInfo.environment,
    explicitProxy: String? = nil
  ) -> [String: String] {
    let allowlist = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"]
    var result: [String: String] = [:]
    for key in allowlist {
      if let value = environment[key], !value.contains("\0") {
        result[key] = value
      }
    }
    // Never inherit ambient proxy settings. A product-configured proxy is
    // passed through the engine's dedicated environment contract so
    // credentials are not exposed in argv or /proc/<pid>/cmdline.
    if let explicitProxy {
      result["OBSCURA_PROXY"] = explicitProxy
    }
    result["NO_PROXY"] = "127.0.0.1,localhost"
    result["no_proxy"] = "127.0.0.1,localhost"
    return result
  }
}
