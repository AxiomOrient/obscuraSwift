import Foundation
import XCTest

@testable import ObscuraKit

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

final class AdapterTests: XCTestCase, @unchecked Sendable {
  func testEngineProcessCapturesCompleteExitDiagnostics() async throws {
    let process = try await launchShell(
      "printf 'stdout-evidence'; printf 'stderr-evidence' >&2; exit 7")
    let exit = try await process.waitForExit()
    XCTAssertEqual(exit, EngineExit(exitCode: 7))
    let diagnostics = await process.diagnosticSnapshot()
    XCTAssertTrue(diagnostics.contains("stdout-evidence"))
    XCTAssertTrue(diagnostics.contains("stderr-evidence"))
  }

  func testEngineProcessRejectsMissingExecutableAtExecBoundary() async {
    let launch = EngineProcessLaunch(
      executable: URL(fileURLWithPath: "/definitely/missing/obscura"),
      arguments: [],
      environment: EngineEnvironment.sanitized(),
      shutdownGrace: .milliseconds(50),
      diagnosticByteLimit: 4_096
    )
    do {
      _ = try await EngineProcess.launch(launch)
      XCTFail("expected launch failure")
    } catch {
      guard case .processLaunchFailed(let errnoValue, _) = error as? ObscuraError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(errnoValue, ENOENT)
    }
  }

  func testEngineProcessBoundsDiagnosticFlood() async throws {
    let process = try await launchShell("head -c 131072 /dev/zero | tr '\\000' X >&2")
    _ = try await process.waitForExit()
    let diagnostics = await process.diagnosticSnapshot()
    XCTAssertLessThanOrEqual(diagnostics.utf8.count, 4_096)
    XCTAssertFalse(diagnostics.isEmpty)
  }

  func testDiagnosticLimitAppliesToCombinedStreams() async {
    let buffer = BoundedDiagnosticBuffer(limit: 128)
    await buffer.appendStdout(Data(repeating: UInt8(ascii: "O"), count: 512))
    await buffer.appendStderr(Data(repeating: UInt8(ascii: "E"), count: 512))
    let diagnostics = await buffer.snapshot()
    XCTAssertLessThanOrEqual(diagnostics.utf8.count, 128)
    XCTAssertTrue(diagnostics.contains("E"))
  }

  func testEngineProcessEscalatesStubbornProcessGroup() async throws {
    let process = try await launchShell(
      "trap '' TERM; while :; do sleep 1; done", grace: .milliseconds(40))
    try await Task.sleep(for: .milliseconds(80))
    let exit = try await process.stop()
    XCTAssertEqual(exit.signal, SIGKILL)
    let isRunning = await process.isRunning()
    XCTAssertFalse(isRunning)
  }

  func testEngineProcessLeaderExitTerminatesPipeHoldingDescendant() async throws {
    let temporary = try TemporaryDirectory(prefix: "ProcessDescendant")
    defer { temporary.remove() }
    let pidFile = temporary.url.appendingPathComponent("descendant.pid")
    let command =
      "(sleep 30) & child=$!; printf '%s' \"$child\" > \(shellQuote(pidFile.path)); exit 0"
    let process = try await launchShell(command)

    let exit = try await withTimeout(.seconds(2)) {
      try await process.waitForExit()
    }
    XCTAssertEqual(exit, EngineExit(exitCode: 0))

    let pidText = try String(contentsOf: pidFile, encoding: .utf8)
    let descendantPID = try XCTUnwrap(Int32(pidText))
    defer { _ = kill(descendantPID, SIGKILL) }
    let stopped = await eventually(timeout: .seconds(2)) {
      kill(descendantPID, 0) != 0 && errno == ESRCH
    }
    XCTAssertTrue(stopped, "descendant retained the engine process group after leader exit")
  }

  #if os(Linux)
    func testEngineProcessClosesUnrelatedInheritedFileDescriptors() async throws {
      let temporary = try TemporaryDirectory(prefix: "ProcessFD")
      defer { temporary.remove() }
      let sentinel = temporary.url.appendingPathComponent("sentinel")
      let descriptor = open(sentinel.path, O_CREAT | O_RDWR, mode_t(0o600))
      XCTAssertGreaterThanOrEqual(descriptor, 0)
      guard descriptor >= 0 else { return }
      defer { _ = close(descriptor) }
      let flags = fcntl(descriptor, F_GETFD)
      XCTAssertGreaterThanOrEqual(flags, 0)
      XCTAssertEqual(fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC), 0)

      let command =
        "actual=$(readlink /proc/self/fd/\(descriptor) 2>/dev/null || true); "
        + "if [ \"$actual\" = \(shellQuote(sentinel.path)) ]; then exit 91; fi"
      let process = try await launchShell(command)
      let exit = try await process.waitForExit()
      XCTAssertEqual(exit, EngineExit(exitCode: 0))
    }
  #endif

  func testEngineEnvironmentIsAllowlistedAndForcesLoopbackNoProxy() {
    let environment = EngineEnvironment.sanitized(from: [
      "PATH": "/bin",
      "HOME": "/tmp/home",
      "SECRET_TOKEN": "must-not-cross",
      "NO_PROXY": "example.test",
      "HTTP_PROXY": "http://proxy.invalid",
      "HTTPS_PROXY": "http://proxy.invalid",
      "SSL_CERT_FILE": "/tmp/ambient-ca.pem",
      "SSL_CERT_DIR": "/tmp/ambient-certs",
      "LD_PRELOAD": "/tmp/inject.so",
      "RUSTY_V8_ARCHIVE": "/tmp/untrusted-v8.a",
      "CARGO_TARGET_DIR": "/tmp/cargo-target",
    ])
    XCTAssertEqual(environment["PATH"], "/bin")
    for rejected in [
      "SECRET_TOKEN", "HTTP_PROXY", "HTTPS_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR",
      "LD_PRELOAD", "RUSTY_V8_ARCHIVE", "CARGO_TARGET_DIR",
    ] {
      XCTAssertNil(environment[rejected], "unexpected inherited environment key \(rejected)")
    }
    XCTAssertEqual(environment["NO_PROXY"], "127.0.0.1,localhost")
    XCTAssertEqual(environment["no_proxy"], "127.0.0.1,localhost")

    let explicit = EngineEnvironment.sanitized(
      from: ["OBSCURA_PROXY": "http://ambient.invalid"],
      explicitProxy: "http://user:secret@127.0.0.1:8080"
    )
    XCTAssertEqual(explicit["OBSCURA_PROXY"], "http://user:secret@127.0.0.1:8080")
  }

  func testWebSocketConfigurationHasNoIndependentSessionLifetimeDeadline() {
    let configuration = FoundationWebSocketTransport.makeSessionConfiguration()
    XCTAssertEqual(
      configuration.timeoutIntervalForResource,
      TimeInterval.greatestFiniteMagnitude
    )
    XCTAssertNil(configuration.urlCache)
    XCTAssertEqual(configuration.connectionProxyDictionary?.count, 0)
  }

  func testPortAllocatorReturnsBindableLoopbackPort() throws {
    let port = try PortAllocator.allocateLoopbackPort()
    XCTAssertNotEqual(port, 0)
    #if canImport(Darwin)
      let socketType = SOCK_STREAM
    #else
      let socketType = Int32(SOCK_STREAM.rawValue)
    #endif
    let socketFD = socket(AF_INET, socketType, 0)
    XCTAssertGreaterThanOrEqual(socketFD, 0)
    defer { _ = close(socketFD) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        #if canImport(Darwin)
          Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        #else
          Glibc.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        #endif
      }
    }
    XCTAssertEqual(result, 0)
  }

  func testEngineLocatorAcceptsExplicitExecutable() throws {
    let executable = try systemTrueExecutable()
    let resolved = try EngineLocator.resolve(.explicit(executable))
    XCTAssertEqual(resolved.path, executable.standardizedFileURL.path)
  }

  func testEngineLocatorAcceptsChromeExecutable() throws {
    let executable = try systemTrueExecutable()
    let resolved = try EngineLocator.resolve(.chrome(executable: executable))
    XCTAssertEqual(resolved.path, executable.standardizedFileURL.path)
  }

  func testChromeLaunchArgumentsAreLoopbackAndIsolated() throws {
    let executable = try systemTrueExecutable()
    let configuration = try LaunchConfiguration(
      executable: .chrome(executable: executable),
      proxy: "http://proxy.example:8080",
      userAgent: "ObscuraKit Chrome Test"
    )
    let profile = URL(fileURLWithPath: "/tmp/ObscuraKit-Chrome-Test", isDirectory: true)
    let arguments = EngineLaunchArguments.chrome(
      port: 9222,
      profileDirectory: profile,
      configuration: configuration
    )
    XCTAssertEqual(
      arguments,
      [
        "--headless=new",
        "--remote-debugging-address=127.0.0.1",
        "--remote-debugging-port=9222",
        "--user-data-dir=/tmp/ObscuraKit-Chrome-Test",
        "--no-first-run",
        "--no-default-browser-check",
        "about:blank",
        "--proxy-server=http://proxy.example:8080",
        "--user-agent=ObscuraKit Chrome Test",
      ]
    )
  }

  func testChromeControlPlaneDiscoversInstalledChromeWhenAvailable() async throws {
    let chrome = URL(
      fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      isDirectory: false
    )
    guard FileManager.default.isExecutableFile(atPath: chrome.path) else {
      throw XCTSkip("Google Chrome is not installed on this host")
    }
    let directory = try TemporaryDirectory(prefix: "ChromeControlPlane")
    defer { directory.remove() }
    let profile = directory.url.appendingPathComponent("profile", isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
    let port = try PortAllocator.allocateLoopbackPort()
    let configuration = try LaunchConfiguration(executable: .chrome(executable: chrome))
    let process = try await EngineProcess.launch(
      EngineProcessLaunch(
        executable: chrome,
        arguments: EngineLaunchArguments.chrome(
          port: port,
          profileDirectory: profile,
          configuration: configuration
        ),
        environment: EngineEnvironment.sanitized(),
        shutdownGrace: .seconds(1),
        diagnosticByteLimit: 64 * 1024
      )
    )
    do {
      let endpoint = try await LoopbackEngineControlPlane().discover(
        port: port,
        flavor: .chrome,
        timeout: .seconds(15)
      )
      XCTAssertEqual(endpoint.engineFlavor, .chrome)
      XCTAssertTrue(endpoint.browserWebSocketURL.path.hasPrefix("/devtools/browser/"))
      _ = try await process.stop()
    } catch {
      let diagnostics = await process.diagnosticSnapshot()
      _ = try? await process.stop()
      XCTFail("Chrome discovery failed: \(error); diagnostics: \(diagnostics)")
    }
  }

  func testEngineLocatorAcceptsExplicitExecutableSymlink() throws {
    let temporary = try TemporaryDirectory(prefix: "ExplicitEngineSymlink")
    defer { temporary.remove() }
    let executable = try systemTrueExecutable()
    let engine = temporary.url.appendingPathComponent("obscura")
    XCTAssertEqual(symlink(executable.path, engine.path), 0)

    let resolved = try EngineLocator.resolve(.explicit(engine))
    XCTAssertEqual(resolved.path, engine.standardizedFileURL.path)
  }

  func testEngineLocatorAllowsSymlinkOutsideVendorBoundary() throws {
    let temporary = try TemporaryDirectory(prefix: "VendoredParent")
    defer { temporary.remove() }
    let actualRoot = temporary.url.appendingPathComponent("actual", isDirectory: true)
    let release = actualRoot.appendingPathComponent(
      "Vendor/Obscura/target/release",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
    let executable = try systemTrueExecutable()
    let engine = release.appendingPathComponent("obscura")
    try FileManager.default.copyItem(at: executable, to: engine)
    XCTAssertEqual(chmod(engine.path, mode_t(0o755)), 0)
    let linkedRoot = temporary.url.appendingPathComponent("linked-root", isDirectory: true)
    XCTAssertEqual(symlink(actualRoot.path, linkedRoot.path), 0)

    let resolved = try EngineLocator.resolve(.vendored(repositoryRoot: linkedRoot))
    XCTAssertEqual(
      resolved.path,
      linkedRoot.appendingPathComponent("Vendor/Obscura/target/release/obscura").path
    )
  }

  func testEngineLocatorRejectsSymlinkInsideVendoredBoundary() throws {
    let temporary = try TemporaryDirectory(prefix: "EngineLocator")
    defer { temporary.remove() }
    let release = temporary.url
      .appendingPathComponent("Vendor/Obscura/target/release", isDirectory: true)
    try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
    let executable = try systemTrueExecutable()
    let engine = release.appendingPathComponent("obscura")
    XCTAssertEqual(symlink(executable.path, engine.path), 0)
    XCTAssertThrowsError(try EngineLocator.resolve(.vendored(repositoryRoot: temporary.url))) {
      error in
      guard case .executableRejected = error as? ObscuraError else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testControlPlaneValidatesExactFixtureDiscoveryContract() async throws {
    let fixture = try FixtureExecutable.make()
    defer { fixture.forceCleanup() }
    let port = try PortAllocator.allocateLoopbackPort()
    let process = try await launchFixture(fixture, port: port)
    do {
      let endpoint = try await LoopbackEngineControlPlane().discover(
        port: port, timeout: .seconds(2))
      XCTAssertEqual(endpoint.protocolVersion, "1.3")
      XCTAssertEqual(endpoint.browserWebSocketURL.path, "/devtools/browser")
      XCTAssertEqual(endpoint.pageTargetID, "page-1")
      _ = try await process.stop()
    } catch {
      _ = try? await process.stop()
      throw error
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testControlPlaneUsesVendorSafeAcceptHeader() async throws {
    let fixture = try FixtureExecutable.make(mode: "accept-sensitive-protocol")
    defer { fixture.forceCleanup() }
    let port = try PortAllocator.allocateLoopbackPort()
    let process = try await launchFixture(fixture, port: port)
    do {
      let endpoint = try await LoopbackEngineControlPlane().discover(
        port: port, timeout: .seconds(2))
      XCTAssertEqual(endpoint.protocolVersion, "1.3")
      let protocolRequest = try XCTUnwrap(
        fixture.requestRecords().last(where: { $0["httpPath"] as? String == "/json/protocol" }))
      let headers = try XCTUnwrap(protocolRequest["headers"] as? [String: String])
      XCTAssertEqual(headers["accept"], "*/*")
      _ = try await process.stop()
    } catch {
      _ = try? await process.stop()
      throw error
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testControlPlaneRetriesTransientReadDeadlineUntilReady() async throws {
    let fixture = try FixtureExecutable.make(mode: "delayed-first-discovery", delaySeconds: 0.7)
    defer { fixture.forceCleanup() }
    let port = try PortAllocator.allocateLoopbackPort()
    let process = try await launchFixture(fixture, port: port)
    do {
      let endpoint = try await LoopbackEngineControlPlane().discover(
        port: port,
        timeout: .seconds(3)
      )
      XCTAssertEqual(endpoint.protocolVersion, "1.3")
      let versionRequests = try fixture.requestRecords().filter {
        $0["httpPath"] as? String == "/json/version"
      }
      XCTAssertGreaterThanOrEqual(versionRequests.count, 2)
      _ = try await process.stop()
    } catch {
      _ = try? await process.stop()
      throw error
    }
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testControlPlaneRejectsDuplicateContentLength() async throws {
    let fixture = try FixtureExecutable.make(mode: "duplicate-content-length")
    defer { fixture.forceCleanup() }
    let port = try PortAllocator.allocateLoopbackPort()
    let process = try await launchFixture(fixture, port: port)
    do {
      _ = try await LoopbackEngineControlPlane().discover(port: port, timeout: .seconds(2))
      XCTFail("expected duplicate Content-Length rejection")
    } catch {
      guard case .controlPlane(let message) = error as? ObscuraError else {
        _ = try? await process.stop()
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("duplicate content-length"))
    }
    _ = try await process.stop()
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testControlPlaneRejectsTransferEncoding() async throws {
    let fixture = try FixtureExecutable.make(mode: "transfer-encoding")
    defer { fixture.forceCleanup() }
    let port = try PortAllocator.allocateLoopbackPort()
    let process = try await launchFixture(fixture, port: port)
    do {
      _ = try await LoopbackEngineControlPlane().discover(port: port, timeout: .seconds(2))
      XCTFail("expected Transfer-Encoding rejection")
    } catch {
      guard case .controlPlane(let message) = error as? ObscuraError else {
        _ = try? await process.stop()
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("Transfer-Encoding is not supported"))
    }
    _ = try await process.stop()
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testControlPlaneRejectsContentTypePrefixSpoofing() async throws {
    let fixture = try FixtureExecutable.make(mode: "invalid-content-type")
    defer { fixture.forceCleanup() }
    let port = try PortAllocator.allocateLoopbackPort()
    let process = try await launchFixture(fixture, port: port)
    do {
      _ = try await LoopbackEngineControlPlane().discover(port: port, timeout: .seconds(2))
      XCTFail("expected invalid Content-Type rejection")
    } catch {
      guard case .controlPlane(let message) = error as? ObscuraError else {
        _ = try? await process.stop()
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("invalid Content-Type"))
    }
    _ = try await process.stop()
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testControlPlaneRejectsSignedContentLength() async throws {
    let fixture = try FixtureExecutable.make(mode: "signed-content-length")
    defer { fixture.forceCleanup() }
    let port = try PortAllocator.allocateLoopbackPort()
    let process = try await launchFixture(fixture, port: port)
    do {
      _ = try await LoopbackEngineControlPlane().discover(port: port, timeout: .seconds(2))
      XCTFail("expected signed Content-Length rejection")
    } catch {
      guard case .controlPlane(let message) = error as? ObscuraError else {
        _ = try? await process.stop()
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("invalid Content-Length"))
    }
    _ = try await process.stop()
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testControlPlaneRejectsMalformedDiscoveryWithoutRetryingSemanticFailure() async throws {
    let fixture = try FixtureExecutable.make(mode: "malformed-discovery")
    defer { fixture.forceCleanup() }
    let port = try PortAllocator.allocateLoopbackPort()
    let process = try await launchFixture(fixture, port: port)
    let started = ContinuousClock().now
    do {
      _ = try await LoopbackEngineControlPlane().discover(port: port, timeout: .seconds(2))
      XCTFail("expected malformed discovery failure")
    } catch {
      guard case .controlPlane(let message) = error as? ObscuraError else {
        _ = try? await process.stop()
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("invalid discovery JSON"))
    }
    XCTAssertLessThan(started.duration(to: ContinuousClock().now), .seconds(1))
    _ = try await process.stop()
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  func testControlPlaneRejectsDeclaredResponseLargerThanConfiguredLimitWithoutRetrying()
    async throws
  {
    let fixture = try FixtureExecutable.make(mode: "oversized-discovery")
    defer { fixture.forceCleanup() }
    let port = try PortAllocator.allocateLoopbackPort()
    let process = try await launchFixture(fixture, port: port)
    do {
      _ = try await LoopbackEngineControlPlane(maximumResponseBytes: 64 * 1024)
        .discover(port: port, timeout: .seconds(2))
      XCTFail("expected response limit failure")
    } catch {
      guard case .controlPlane(let message) = error as? ObscuraError else {
        _ = try? await process.stop()
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("exceeded configured limit"))
    }
    let versionRequests = try fixture.requestRecords().filter {
      $0["httpPath"] as? String == "/json/version"
    }
    XCTAssertEqual(versionRequests.count, 1)
    _ = try await process.stop()
    let stopped = await fixture.waitUntilStopped()
    XCTAssertTrue(stopped)
  }

  private func launchShell(_ command: String, grace: Duration = .milliseconds(100)) async throws
    -> EngineProcess
  {
    try await EngineProcess.launch(
      EngineProcessLaunch(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", command],
        environment: EngineEnvironment.sanitized(),
        shutdownGrace: grace,
        diagnosticByteLimit: 4_096
      )
    )
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func launchFixture(_ fixture: FixtureExecutable, port: UInt16) async throws
    -> EngineProcess
  {
    try await EngineProcess.launch(
      EngineProcessLaunch(
        executable: fixture.executable,
        arguments: [
          "serve", "--host", "127.0.0.1", "--port", String(port),
          "--workers", "1", "--max-connections", "1", "--quiet",
        ],
        environment: EngineEnvironment.sanitized(),
        shutdownGrace: .milliseconds(100),
        diagnosticByteLimit: 8 * 1024
      )
    )
  }
}
