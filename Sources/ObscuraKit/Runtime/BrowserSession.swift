import Foundation

public actor BrowserSession {
  private enum InvariantDisposition {
    case quarantined
    case closed
  }

  private struct OperationWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
  }

  private let configuration: LaunchConfiguration
  private let dependencies: RuntimeDependencies
  private var state: SessionState
  private var process: (any EngineProcessHandle)?
  private var connection: CDPConnection?
  private var port: UInt16?
  private var chromeProfileDirectory: URL?
  private var nextOperationID: UInt64 = 1
  private var operationPermitHeld = false
  private var operationWaiters: [OperationWaiter] = []
  private var supervisionTask: Task<Void, Never>?
  private var eventContinuations: [UUID: AsyncStream<SessionSnapshot>.Continuation] = [:]
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []

  private init(configuration: LaunchConfiguration, dependencies: RuntimeDependencies) {
    self.configuration = configuration
    self.dependencies = dependencies
    self.state = SessionState()
  }

  deinit {
    // Explicit `close()` is the authoritative lifecycle boundary. This path is
    // only crash/leak containment for owners that abandon a live session.
    supervisionTask?.cancel()
    process?.terminateImmediately()
    if process == nil, let directory = chromeProfileDirectory {
      try? FileManager.default.removeItem(at: directory)
    }
    for continuation in eventContinuations.values {
      continuation.finish()
    }
  }

  public static func launch(_ configuration: LaunchConfiguration) async throws -> BrowserSession {
    try await launch(configuration, dependencies: .live)
  }

  internal static func launch(
    _ configuration: LaunchConfiguration,
    dependencies: RuntimeDependencies
  ) async throws -> BrowserSession {
    let session = BrowserSession(configuration: configuration, dependencies: dependencies)
    do {
      try await withTimeout(configuration.startupTimeout) {
        try await session.start()
      }
      return session
    } catch TimeoutSentinel.elapsed {
      let primary = ObscuraError.startupTimedOut
      if let cleanup = await session.forceCleanupAfterFailedStart() {
        throw ObscuraError.recoveryFailed(
          primary: primary.description, recovery: cleanup.description)
      }
      throw primary
    } catch {
      let primary = mapError(error)
      if let cleanup = await session.forceCleanupAfterFailedStart() {
        throw ObscuraError.recoveryFailed(
          primary: primary.description, recovery: cleanup.description)
      }
      throw primary
    }
  }

  public var id: SessionID { state.id }

  public func snapshot() -> SessionSnapshot { state.snapshot }

  internal var operationQueueDepth: Int { operationWaiters.count }

  public func snapshots() -> AsyncStream<SessionSnapshot> {
    let id = UUID()
    let current = state.snapshot
    return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
      continuation.yield(current)
      if state.phase == .closed {
        continuation.finish()
      } else {
        eventContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
          guard let self else { return }
          Task { await self.removeEventContinuation(id) }
        }
      }
    }
  }

  public func navigate(
    to url: URL,
    waitUntil: NavigationWait = .domContentLoaded,
    timeout: Duration? = nil
  ) async throws -> NavigationResult {
    try validateNavigationURL(url)
    let navigation: (String, String?) = try await performOperation(.navigate(url), timeout: timeout)
    { connection, deadline in
      let response = try await connection.callPage(
        "Page.navigate",
        params: .object([
          "url": .string(url.absoluteString),
          "waitUntil": .string(waitUntil.rawValue),
        ]),
        timeout: try deadline.remaining(for: "Page.navigate")
      )
      guard case .object(let object) = response,
        let frameID = object["frameId"]?.stringValue
      else {
        throw ObscuraError.protocolViolation("Page.navigate response is missing frameId")
      }
      return (frameID, object["loaderId"]?.stringValue)
    }
    return NavigationResult(
      url: url,
      frameID: navigation.0,
      loaderID: navigation.1,
      generation: state.generation
    )
  }

  public func evaluate<T: Decodable & Sendable>(
    _ source: String,
    as type: T.Type = T.self,
    timeout: Duration? = nil
  ) async throws -> T {
    try await performOperation(.evaluate, timeout: timeout) { connection, deadline in
      try await Self.evaluate(
        source,
        as: type,
        using: connection,
        timeout: try deadline.remaining(for: "Runtime.evaluate")
      )
    }
  }

  public func evaluateJSON(_ source: String, timeout: Duration? = nil) async throws -> JSONValue {
    try await evaluate(source, as: JSONValue.self, timeout: timeout)
  }

  public func title(timeout: Duration? = nil) async throws -> String {
    try await evaluate("document.title", as: String.self, timeout: timeout)
  }

  public func currentURL(timeout: Duration? = nil) async throws -> URL {
    try await performOperation(.evaluate, timeout: timeout) { connection, deadline in
      let value = try await Self.evaluate(
        "location.href",
        as: String.self,
        using: connection,
        timeout: try deadline.remaining(for: "Runtime.evaluate")
      )
      guard let url = URL(string: value), Self.pageURLViolation(url) == nil else {
        throw ObscuraError.protocolViolation("engine returned an invalid absolute page URL")
      }
      return url
    }
  }

  public func content(timeout: Duration? = nil) async throws -> String {
    try await evaluate("document.documentElement.outerHTML", as: String.self, timeout: timeout)
  }

  public func locator(_ selector: CSSSelector) -> Locator {
    Locator(session: self, selector: selector)
  }

  public func cookies(timeout: Duration? = nil) async throws -> [Cookie] {
    try await performOperation(.readCookies, timeout: timeout) { connection, deadline in
      let response = try await connection.callPage(
        "Network.getAllCookies",
        timeout: try deadline.remaining(for: "Network.getAllCookies")
      )
      return try CookieCodec.decode(response)
    }
  }

  public func setCookies(_ cookies: [Cookie], timeout: Duration? = nil) async throws {
    try SessionCheckpoint.validateCookies(cookies, context: "cookie batch")
    try await performOperation(.writeCookies, timeout: timeout) { connection, deadline in
      let encoded = cookies.map(CookieCodec.encode)
      _ = try await connection.callPage(
        "Network.setCookies",
        params: .object(["cookies": .array(encoded)]),
        timeout: try deadline.remaining(for: "Network.setCookies")
      )
      let observed = try CookieCodec.decode(
        try await connection.callPage(
          "Network.getAllCookies",
          timeout: try deadline.remaining(for: "Network.getAllCookies")
        )
      )
      for expected in cookies {
        guard
          observed.contains(where: {
            CookieCodec.satisfiesPostcondition(observed: $0, expected: expected)
          })
        else {
          throw ObscuraError.cookieRejected(
            "engine did not retain \(expected.name) for \(expected.domain)\(expected.path)")
        }
      }
    }
  }

  public func checkpoint(timeout: Duration? = nil) async throws -> SessionCheckpoint {
    let values = try await cookies(timeout: timeout)
    return try SessionCheckpoint(compatibility: configuration.compatibility, cookies: values)
  }

  public func recover(from checkpoint: SessionCheckpoint) async throws -> BrowserSession {
    guard checkpoint.compatibility == configuration.compatibility else {
      throw ObscuraError.incompatibleCheckpoint("launch compatibility does not match")
    }
    guard state.phase == .quarantined else {
      throw ObscuraError.invalidState("recovery is only valid for a quarantined session")
    }
    let primaryFailure =
      state.failure ?? .quarantined("session entered recovery without failure evidence")
    let effects = try apply(.recoveryRequested(checkpoint))
    guard effects == [.shutdown, .launchReplacement(checkpoint)] else {
      throw ObscuraError.invalidState("recovery reducer emitted an unexpected effect set")
    }
    if let shutdownError = await shutdownResources() {
      try requireActiveRecovery()
      let recoveryFailure = recordReplacementFailure(
        shutdownError,
        context: "recording original-session shutdown failure"
      )
      finishEventStreamsIfClosed()
      throw ObscuraError.recoveryFailed(
        primary: primaryFailure.description,
        recovery: recoveryFailure.description
      )
    }
    try requireActiveRecovery()

    var replacement: BrowserSession?
    do {
      let launched = try await BrowserSession.launch(configuration, dependencies: dependencies)
      replacement = launched
      try requireActiveRecovery()
      let restorableCookies = try checkpoint.restorableCookies(at: dependencies.currentDate())
      if !restorableCookies.isEmpty {
        try await launched.setCookies(restorableCookies)
      }
      try requireActiveRecovery()
      _ = try apply(.replacementSucceeded)
      finishEventStreamsIfClosed()
      return launched
    } catch {
      await replacement?.close()
      let mapped = Self.mapError(error)
      if state.phase == .closing || state.phase == .closed || mapped == .closed {
        throw ObscuraError.closed
      }
      try requireActiveRecovery()
      let recoveryFailure = recordReplacementFailure(
        mapped,
        context: "recording replacement launch or checkpoint restore failure"
      )
      finishEventStreamsIfClosed()
      throw ObscuraError.recoveryFailed(
        primary: primaryFailure.description,
        recovery: recoveryFailure.description
      )
    }
  }

  public func close() async {
    if state.phase == .closed { return }
    if state.phase == .closing {
      await waitUntilClosed()
      return
    }
    supervisionTask?.cancel()
    supervisionTask = nil
    let effects: [SessionEffect]
    do {
      effects = try apply(.closeRequested)
    } catch {
      var failure = recordInvariantViolation(
        error,
        context: "applying closeRequested",
        disposition: .closed
      )
      if let cleanup = await shutdownResources() {
        failure = Self.mergeFailures(primary: failure, secondary: cleanup)
        installForcedClosed(failure)
      }
      failQueuedOperations(with: .closed)
      finishEventStreamsIfClosed()
      return
    }
    if effects.contains(.shutdown) {
      let shutdownError = await shutdownResources()
      recordShutdownResult(
        shutdownError,
        context: "finalizing explicit close",
        disposition: .closed
      )
    }
    failQueuedOperations(with: .closed)
    finishEventStreamsIfClosed()
  }

  internal func locatorText(_ selector: CSSSelector, timeout: Duration?) async throws -> String? {
    try await evaluateElement(
      selector,
      operation: "text",
      sessionOperation: .readDOM,
      timeout: timeout
    ) { "__obscuraKitElement.textContent" } as String?
  }

  internal func locatorAttribute(_ selector: CSSSelector, name: String, timeout: Duration?)
    async throws -> String?
  {
    guard !name.isEmpty, name.utf8.count <= 512, !name.contains("\0") else {
      throw ObscuraError.invalidConfiguration("invalid attribute name")
    }
    let literal = try Self.jsonLiteral(name)
    return try await evaluateElement(
      selector,
      operation: "attribute",
      sessionOperation: .readDOM,
      timeout: timeout
    ) {
      "__obscuraKitElement.getAttribute(\(literal))"
    } as String?
  }

  internal func locatorClick(_ selector: CSSSelector, timeout: Duration?) async throws {
    let _: Bool = try await evaluateElement(
      selector,
      operation: "click",
      sessionOperation: .mutateDOM,
      timeout: timeout
    ) {
      "(__obscuraKitElement.click(), true)"
    }
  }

  internal func locatorSetValue(_ selector: CSSSelector, value: String, timeout: Duration?)
    async throws
  {
    guard value.utf8.count <= 1_048_576, !value.contains("\0") else {
      throw ObscuraError.invalidConfiguration("invalid element value")
    }
    let literal = try Self.jsonLiteral(value)
    let _: Bool = try await evaluateElement(
      selector,
      operation: "setValue",
      sessionOperation: .mutateDOM,
      timeout: timeout
    ) {
      """
      (function () {
        const prototype = Object.getPrototypeOf(__obscuraKitElement);
        const descriptor = Object.getOwnPropertyDescriptor(prototype, "value");
        if (descriptor && descriptor.set) descriptor.set.call(__obscuraKitElement, \(literal));
        else __obscuraKitElement.value = \(literal);
        __obscuraKitElement.dispatchEvent(new Event("input", { bubbles: true }));
        __obscuraKitElement.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      })()
      """
    }
  }

  private func start() async throws {
    var effects = try apply(.startRequested)
    guard effects == [.launchProcess] else {
      throw ObscuraError.invalidState("startup did not request process launch")
    }

    let executable = try EngineLocator.resolve(configuration.executable)
    let port = try PortAllocator.allocateLoopbackPort()
    self.port = port
    let flavor = configuration.executable.engineFlavor
    let arguments: [String]
    switch flavor {
    case .obscura:
      arguments = EngineLaunchArguments.obscura(port: port, configuration: configuration)
    case .chrome:
      let profile = try makeChromeProfileDirectory()
      chromeProfileDirectory = profile
      arguments = EngineLaunchArguments.chrome(
        port: port,
        profileDirectory: profile,
        configuration: configuration
      )
    }
    let launched = try await dependencies.launchProcess(
      EngineProcessLaunch(
        executable: executable,
        arguments: arguments,
        environment: EngineEnvironment.sanitized(
          explicitProxy: flavor == .obscura ? configuration.proxy : nil),
        shutdownGrace: configuration.shutdownGrace,
        diagnosticByteLimit: configuration.diagnosticByteLimit
      )
    )
    process = launched
    effects = try apply(.processLaunched)
    guard effects == [.discoverControlPlane] else {
      throw ObscuraError.invalidState("startup did not request discovery")
    }

    let endpoint = try await raceDiscoveryAgainstExit(
      process: launched,
      port: port,
      flavor: flavor
    )
    effects = try apply(.controlPlaneDiscovered)
    guard effects == [.connectTransport] else {
      throw ObscuraError.invalidState("startup did not request transport")
    }

    let transport = try dependencies.makeTransport(
      endpoint.browserWebSocketURL, configuration.maximumMessageBytes)
    let connection = CDPConnection(
      transport: transport, maximumMessageBytes: configuration.maximumMessageBytes)
    self.connection = connection
    try await connection.connect()
    effects = try apply(.transportConnected)
    guard effects == [.initializeProtocol] else {
      throw ObscuraError.invalidState("startup did not request initialization")
    }

    try await VendoredObscuraSessionBootstrap.initialize(
      connection: connection,
      endpoint: endpoint,
      timeout: configuration.operationTimeout
    )
    _ = try apply(.protocolInitialized)
    startSupervision(process: launched, connection: connection)
  }

  private func raceDiscoveryAgainstExit(
    process: any EngineProcessHandle,
    port: UInt16,
    flavor: EngineFlavor
  ) async throws -> EngineEndpoint {
    enum Outcome: Sendable {
      case endpoint(EngineEndpoint)
      case exited(EngineExit)
    }
    let controlPlane = dependencies.controlPlane
    let timeout = configuration.startupTimeout
    return try await withThrowingTaskGroup(of: Outcome.self) { group in
      group.addTask {
        .endpoint(try await controlPlane.discover(port: port, flavor: flavor, timeout: timeout))
      }
      group.addTask { .exited(try await process.waitForExit()) }
      guard let first = try await group.next() else { throw ObscuraError.startupTimedOut }
      group.cancelAll()
      switch first {
      case .endpoint(let endpoint): return endpoint
      case .exited(let exit):
        let diagnostics = await process.diagnosticSnapshot()
        throw ObscuraError.engineExited(exit: exit, diagnostics: diagnostics)
      }
    }
  }

  private func startSupervision(process: any EngineProcessHandle, connection: CDPConnection) {
    supervisionTask?.cancel()
    supervisionTask = Task { [weak self] in
      enum Outcome: Sendable {
        case process(EngineExit)
        case transport(ObscuraError?)
      }
      let outcome = await withTaskGroup(of: Outcome.self) { group in
        group.addTask {
          do { return .process(try await process.waitForExit()) } catch {
            return .transport(.transport("process monitor failed: \(error)"))
          }
        }
        group.addTask { .transport(await connection.waitForTermination()) }
        let first = await group.next()!
        group.cancelAll()
        return first
      }
      guard !Task.isCancelled else { return }
      switch outcome {
      case .process(let exit):
        let diagnostics = await process.diagnosticSnapshot()
        await self?.handleSupervisionFailure(.engineExited(exit: exit, diagnostics: diagnostics))
      case .transport(let error):
        await self?.handleSupervisionFailure(
          error ?? .transport("CDP connection closed unexpectedly"))
      }
    }
  }

  private func handleSupervisionFailure(_ error: ObscuraError) async {
    guard state.phase != .closing, state.phase != .closed, state.phase != .quarantined,
      state.phase != .recovering
    else { return }
    let effects: [SessionEffect]
    var surfacedFailure = error
    do {
      effects = try apply(.supervisionFailed(error))
    } catch {
      let invariant = recordInvariantViolation(
        error,
        context: "applying supervisionFailed",
        disposition: .quarantined
      )
      surfacedFailure = Self.mergeFailures(primary: surfacedFailure, secondary: invariant)
      effects = [.shutdown]
    }
    if effects.contains(.shutdown) {
      let shutdownError = await shutdownResources()
      if let transitionFailure = recordTerminalShutdownResult(
        shutdownError,
        context: "finalizing supervised failure"
      ) {
        surfacedFailure = Self.mergeFailures(
          primary: surfacedFailure,
          secondary: transitionFailure
        )
      }
    }
    failQueuedOperations(with: surfacedFailure)
  }

  private func performOperation<T: Sendable>(
    _ operation: SessionOperation,
    timeout: Duration?,
    body: @escaping @Sendable (CDPConnection, OperationDeadline) async throws -> T
  ) async throws -> T {
    try requireOperationAcceptance()
    try await acquireOperationPermit()
    defer { releaseOperationPermit() }
    // Actor reentrancy permits close, quarantine, or recovery while this call
    // is suspended in the queue. Revalidate ownership before dispatch.
    try requireOperationAcceptance()
    if Task.isCancelled {
      throw ObscuraError.cancelled("operation before dispatch")
    }
    guard let connection else { throw availabilityError() }
    guard nextOperationID < UInt64.max else {
      throw ObscuraError.resourceLimit("operation identifier exhausted")
    }
    let effectiveTimeout = timeout ?? configuration.operationTimeout
    guard effectiveTimeout > .zero else {
      throw ObscuraError.invalidConfiguration("operation timeout must be positive")
    }
    let id = OperationID(nextOperationID)
    nextOperationID += 1
    let effects = try apply(.operationRequested(id: id, operation: operation))
    guard effects == [.dispatch(id: id, operation: operation)] else {
      throw ObscuraError.invalidState("operation reducer emitted unexpected effects")
    }
    let outcome: Result<T, Error>
    do {
      outcome = .success(
        try await body(connection, OperationDeadline(timeout: effectiveTimeout)))
    } catch {
      outcome = .failure(error)
    }

    switch outcome {
    case .success(let value):
      if let interruption = finishInterruptedOperationIfNeeded(id: id) {
        throw interruption
      }
      _ = try apply(.operationSucceeded(id: id, operation: operation))
      return value

    case .failure(let error):
      if let interruption = finishInterruptedOperationIfNeeded(id: id) {
        throw interruption
      }
      let mapped = Self.mapError(error)
      let terminal = mapped.requiresQuarantine
      let effects: [SessionEffect]
      var surfacedFailure = mapped
      do {
        effects = try apply(.operationFailed(id: id, error: mapped, terminal: terminal))
      } catch {
        let invariant = recordInvariantViolation(
          error,
          context: "applying operationFailed for \(operation)",
          disposition: .quarantined
        )
        surfacedFailure = Self.mergeFailures(primary: mapped, secondary: invariant)
        effects = [.shutdown]
      }
      if effects.contains(.shutdown) {
        supervisionTask?.cancel()
        supervisionTask = nil
        let shutdownError = await shutdownResources()
        if let transitionFailure = recordTerminalShutdownResult(
          shutdownError,
          context: "finalizing failed operation \(operation)"
        ) {
          surfacedFailure = Self.mergeFailures(
            primary: surfacedFailure,
            secondary: transitionFailure
          )
        }
        failQueuedOperations(with: surfacedFailure)
      }
      throw surfacedFailure
    }
  }

  /// Completes an operation that was interrupted by an explicit terminal
  /// transition while its asynchronous effect was still unwinding. The
  /// terminal failure wins over any stale success or transport error.
  private func finishInterruptedOperationIfNeeded(id: OperationID) -> ObscuraError? {
    guard state.interruptedOperation == id else { return nil }
    let terminalFailure = state.failure ?? availabilityError()
    do {
      _ = try apply(.interruptedOperationCompleted(id: id))
      return terminalFailure
    } catch {
      let invariant = recordInvariantViolation(
        error,
        context: "completing interrupted operation \(id)",
        disposition: state.phase == .closed ? .closed : .quarantined
      )
      return Self.mergeFailures(primary: terminalFailure, secondary: invariant)
    }
  }

  private func evaluateElement<T: Decodable & Sendable>(
    _ selector: CSSSelector,
    operation: String,
    sessionOperation: SessionOperation,
    timeout: Duration? = nil,
    expression: () throws -> String
  ) async throws -> T {
    let selectorLiteral = try Self.jsonLiteral(selector.rawValue)
    let valueExpression = try expression()
    let script = """
      (function () {
        const __obscuraKitElement = document.querySelector(\(selectorLiteral));
        if (!__obscuraKitElement) return { __obscuraKitElementMissing: true };
        return { __obscuraKitElementMissing: false, value: \(valueExpression) };
      })()
      """
    let envelope: JSONValue = try await performOperation(sessionOperation, timeout: timeout) {
      connection, deadline in
      try await Self.evaluate(
        script,
        as: JSONValue.self,
        using: connection,
        timeout: try deadline.remaining(for: "Runtime.evaluate")
      )
    }
    guard case .object(let object) = envelope,
      let missing = object["__obscuraKitElementMissing"]?.boolValue
    else {
      throw ObscuraError.protocolViolation("locator \(operation) returned a malformed envelope")
    }
    guard !missing else { throw ObscuraError.elementNotFound(selector.rawValue) }
    let value = object["value"] ?? .null
    do {
      return try value.decode(T.self)
    } catch let error as ObscuraError {
      throw error
    } catch {
      throw ObscuraError.protocolViolation("locator \(operation) value decode failed: \(error)")
    }
  }

  private func acquireOperationPermit() async throws {
    if !operationPermitHeld {
      operationPermitHeld = true
      return
    }
    guard operationWaiters.count < configuration.maximumQueuedOperations else {
      throw ObscuraError.sessionBusy(limit: configuration.maximumQueuedOperations)
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: ObscuraError.cancelled("queued operation"))
        } else {
          operationWaiters.append(OperationWaiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelOperationWaiter(id) }
    }
  }

  private func requireOperationAcceptance() throws {
    switch state.phase {
    case .ready, .executing:
      return
    case .quarantined:
      throw ObscuraError.quarantined(state.failure?.description ?? "unknown failure")
    case .closing, .closed:
      throw ObscuraError.closed
    case .recovering:
      throw ObscuraError.invalidState("session is recovering")
    case .idle, .starting:
      throw ObscuraError.invalidState("session is not ready")
    }
  }

  private func releaseOperationPermit() {
    if operationWaiters.isEmpty {
      operationPermitHeld = false
    } else {
      let next = operationWaiters.removeFirst()
      next.continuation.resume()
    }
  }

  private func cancelOperationWaiter(_ id: UUID) {
    guard let index = operationWaiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = operationWaiters.remove(at: index)
    waiter.continuation.resume(throwing: ObscuraError.cancelled("queued operation"))
  }

  private func failQueuedOperations(with error: ObscuraError) {
    let waiters = operationWaiters
    operationWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.continuation.resume(throwing: error) }
  }

  @discardableResult
  private func apply(_ event: SessionEvent) throws -> [SessionEffect] {
    let transition = try SessionReducer.reduce(state: state, event: event)
    state = transition.state
    emitSnapshot()
    return transition.effects
  }

  private func emitSnapshot() {
    let snapshot = state.snapshot
    for continuation in eventContinuations.values { continuation.yield(snapshot) }
  }

  private func finishEventStreamsIfClosed() {
    guard state.phase == .closed else { return }
    let continuations = eventContinuations.values
    eventContinuations.removeAll(keepingCapacity: false)
    for continuation in continuations { continuation.finish() }
    let waiters = closeWaiters
    closeWaiters.removeAll(keepingCapacity: false)
    for continuation in waiters { continuation.resume() }
  }

  private func waitUntilClosed() async {
    if state.phase == .closed { return }
    await withCheckedContinuation { continuation in
      if state.phase == .closed {
        continuation.resume()
      } else {
        closeWaiters.append(continuation)
      }
    }
  }

  private func removeEventContinuation(_ id: UUID) {
    eventContinuations.removeValue(forKey: id)
  }

  @discardableResult
  private func shutdownResources() async -> ObscuraError? {
    let connection = self.connection
    let process = self.process
    self.connection = nil
    await connection?.close()
    guard let process else {
      removeChromeProfileDirectory()
      return nil
    }
    do {
      _ = try await process.stop()
      clearProcessIfCurrent(process)
      removeChromeProfileDirectory()
      return nil
    } catch {
      let primary = Self.mapError(error)
      process.terminateImmediately()
      do {
        _ = try await withTimeout(configuration.shutdownGrace) {
          try await process.waitForExit()
        }
        clearProcessIfCurrent(process)
        removeChromeProfileDirectory()
        return primary
      } catch TimeoutSentinel.elapsed {
        return Self.mergeFailures(
          primary: primary,
          secondary: .operationTimedOut("emergency engine termination")
        )
      } catch {
        return Self.mergeFailures(primary: primary, secondary: Self.mapError(error))
      }
    }
  }

  private func clearProcessIfCurrent(_ process: any EngineProcessHandle) {
    if let current = self.process,
      ObjectIdentifier(current as AnyObject) == ObjectIdentifier(process as AnyObject)
    {
      self.process = nil
    }
  }

  private func makeChromeProfileDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ObscuraKit-Chrome-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func removeChromeProfileDirectory() {
    guard let directory = chromeProfileDirectory else { return }
    chromeProfileDirectory = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private func forceCleanupAfterFailedStart() async -> ObscuraError? {
    supervisionTask?.cancel()
    supervisionTask = nil
    var reportedFailure = await shutdownResources()
    if state.phase != .closed {
      do {
        _ = try apply(.closeRequested)
      } catch {
        let invariant = recordInvariantViolation(
          error,
          context: "closing a session after startup failure",
          disposition: .closed
        )
        reportedFailure = Self.mergeFailures(
          primary: reportedFailure,
          secondary: invariant
        )
      }
      if state.phase == .closing {
        if let transitionFailure = recordShutdownResult(
          reportedFailure,
          context: "finalizing cleanup after startup failure",
          disposition: .closed
        ) {
          reportedFailure = transitionFailure
        }
      }
    }
    finishEventStreamsIfClosed()
    return reportedFailure
  }

  @discardableResult
  private func recordReplacementFailure(
    _ failure: ObscuraError,
    context: String
  ) -> ObscuraError {
    do {
      _ = try apply(.replacementFailed(failure))
      return failure
    } catch {
      let invariant = recordInvariantViolation(
        error,
        context: context,
        disposition: .closed
      )
      return Self.mergeFailures(primary: failure, secondary: invariant)
    }
  }

  /// A terminal operation or supervision failure owns the quarantined
  /// shutdown only until another lifecycle action (recovery or close) takes
  /// over. Actor reentrancy can suspend that finalizer after resources are
  /// detached, so a late completion must not be interpreted as an invariant
  /// failure in the new owner phase.
  @discardableResult
  private func recordTerminalShutdownResult(
    _ shutdownError: ObscuraError?,
    context: String
  ) -> ObscuraError? {
    guard state.phase == .quarantined else {
      return shutdownError
    }
    return recordShutdownResult(
      shutdownError,
      context: context,
      disposition: .quarantined
    )
  }

  /// Applies the reducer event corresponding to an already completed
  /// side-effect. Any reducer mismatch is converted into explicit terminal
  /// state evidence rather than being discarded.
  @discardableResult
  private func recordShutdownResult(
    _ shutdownError: ObscuraError?,
    context: String,
    disposition: InvariantDisposition
  ) -> ObscuraError? {
    let event: SessionEvent = shutdownError.map(SessionEvent.shutdownFailed) ?? .shutdownCompleted
    do {
      _ = try apply(event)
      return shutdownError
    } catch {
      let invariant = recordInvariantViolation(
        error,
        context: context,
        disposition: disposition
      )
      return Self.mergeFailures(primary: shutdownError, secondary: invariant)
    }
  }

  @discardableResult
  private func recordInvariantViolation(
    _ error: Error,
    context: String,
    disposition: InvariantDisposition
  ) -> ObscuraError {
    let mapped = Self.mapError(error)
    let invariant = ObscuraError.invalidState("\(context): \(mapped.description)")
    let transition: SessionTransition
    switch disposition {
    case .quarantined:
      transition = SessionReducer.forceQuarantined(state: state, error: invariant)
    case .closed:
      transition = SessionReducer.forceClosed(state: state, error: invariant)
    }
    install(transition)
    return invariant
  }

  private func installForcedClosed(_ failure: ObscuraError) {
    install(SessionReducer.forceClosed(state: state, error: failure))
  }

  private func install(_ transition: SessionTransition) {
    state = transition.state
    emitSnapshot()
  }

  private static func mergeFailures(
    primary: ObscuraError?,
    secondary: ObscuraError
  ) -> ObscuraError {
    guard let primary else { return secondary }
    return .recoveryFailed(primary: primary.description, recovery: secondary.description)
  }

  /// Revalidates recovery ownership after every suspension point. Actor
  /// isolation prevents data races, but actor reentrancy permits `close()` to
  /// win while replacement launch or checkpoint restoration is suspended.
  /// A concurrent close is an expected terminal outcome, not an invariant
  /// failure and not a reason to resurrect the original session.
  private func requireActiveRecovery() throws {
    switch state.phase {
    case .recovering:
      return
    case .closing, .closed:
      throw ObscuraError.closed
    default:
      throw ObscuraError.invalidState(
        "recovery resumed in unexpected phase \(state.phase.rawValue)"
      )
    }
  }

  private func availabilityError() -> ObscuraError {
    switch state.phase {
    case .quarantined: return .quarantined(state.failure?.description ?? "unknown failure")
    case .closed, .closing: return .closed
    default: return .invalidState("session has no active CDP connection")
    }
  }

  private func validateNavigationURL(_ url: URL) throws {
    if let violation = Self.pageURLViolation(url) {
      throw ObscuraError.invalidConfiguration(violation)
    }
  }

  private static func pageURLViolation(_ url: URL) -> String? {
    let serialized = url.absoluteString
    guard serialized.utf8.count <= 65_536, !serialized.contains("\0") else {
      return "navigation URL is invalid or too large"
    }
    guard let scheme = url.scheme?.lowercased(),
      ["http", "https", "data", "about"].contains(scheme)
    else {
      return "navigation URL must use http, https, data, or about"
    }
    if scheme == "http" || scheme == "https" {
      guard let host = url.host, !host.isEmpty else {
        return "HTTP navigation URL must contain a host"
      }
    }
    return nil
  }

  private static func jsonLiteral(_ string: String) throws -> String {
    let data = try JSONEncoder().encode(string)
    guard let value = String(data: data, encoding: .utf8) else {
      throw ObscuraError.protocolViolation("failed to encode JavaScript literal")
    }
    return value
  }

  private static func evaluate<T: Decodable & Sendable>(
    _ source: String,
    as type: T.Type,
    using connection: CDPConnection,
    timeout: Duration
  ) async throws -> T {
    let expression = try EvaluationCodec.expression(for: source)
    let response = try await connection.callPage(
      "Runtime.evaluate",
      params: .object([
        "expression": .string(expression),
        "returnByValue": .bool(true),
        "awaitPromise": .bool(true),
        "timeout": .number(Double(max(1, timeout.wholeMilliseconds))),
      ]),
      timeout: timeout
    )
    return try EvaluationCodec.decode(response, as: type)
  }

  fileprivate static func mapError(_ error: Error) -> ObscuraError {
    if let error = error as? ObscuraError { return error }
    if error is CancellationError { return .cancelled("task") }
    return .transport(String(describing: error))
  }
}

internal enum CookieCodec {
  static func encode(_ cookie: Cookie) -> JSONValue {
    var object: [String: JSONValue] = [
      "name": .string(cookie.name),
      "value": .string(cookie.value),
      "domain": .string(cookie.domain),
      "path": .string(cookie.path),
      "secure": .bool(cookie.secure),
      "httpOnly": .bool(cookie.httpOnly),
    ]
    if let sameSite = cookie.sameSite { object["sameSite"] = .string(sameSite.rawValue) }
    if let expires = cookie.expires { object["expires"] = .number(expires.timeIntervalSince1970) }
    return .object(object)
  }

  static func decode(_ response: JSONValue) throws -> [Cookie] {
    guard case .object(let root) = response,
      case .array(let values)? = root["cookies"]
    else {
      throw ObscuraError.protocolViolation("cookie response is missing cookies array")
    }
    guard values.count <= SessionCheckpoint.maximumCookieCount else {
      throw ObscuraError.resourceLimit(
        "cookie response exceeds \(SessionCheckpoint.maximumCookieCount) entries")
    }
    return try values.map(decodeCookie)
  }

  static func satisfiesPostcondition(observed: Cookie, expected: Cookie) -> Bool {
    guard observed.name == expected.name,
      observed.value == expected.value,
      normalizeDomain(observed.domain) == normalizeDomain(expected.domain),
      observed.path == expected.path,
      observed.secure == expected.secure,
      observed.httpOnly == expected.httpOnly
    else {
      return false
    }
    if let expectedSameSite = expected.sameSite, observed.sameSite != expectedSameSite {
      return false
    }
    switch (observed.expires, expected.expires) {
    case (nil, nil):
      return true
    case (let observed?, let expected?):
      return abs(observed.timeIntervalSince1970 - expected.timeIntervalSince1970) <= 1
    default:
      return false
    }
  }

  private static func decodeCookie(_ value: JSONValue) throws -> Cookie {
    guard case .object(let object) = value else {
      throw ObscuraError.protocolViolation("cookie entry is not an object")
    }
    let name = try requiredString("name", in: object)
    let cookieValue = try requiredString("value", in: object)
    let domain = try requiredString("domain", in: object)
    let path = try requiredString("path", in: object)
    let secure = try requiredBool("secure", in: object)
    let httpOnly = try requiredBool("httpOnly", in: object)

    let sameSite: SameSite?
    if let raw = object["sameSite"] {
      guard case .string(let value) = raw, let decoded = SameSite(rawValue: value) else {
        throw ObscuraError.protocolViolation("cookie sameSite is invalid")
      }
      sameSite = decoded
    } else {
      sameSite = nil
    }

    let expires: Date?
    if let raw = object["expires"] {
      guard case .number(let seconds) = raw, seconds.isFinite else {
        throw ObscuraError.protocolViolation("cookie expires is not a finite number")
      }
      expires = seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    } else {
      expires = nil
    }

    do {
      return try Cookie(
        name: name,
        value: cookieValue,
        domain: domain,
        path: path,
        secure: secure,
        httpOnly: httpOnly,
        sameSite: sameSite,
        expires: expires
      )
    } catch let error as ObscuraError {
      throw ObscuraError.protocolViolation("engine returned invalid cookie: \(error.description)")
    }
  }

  private static func requiredString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = object[key] else {
      throw ObscuraError.protocolViolation("cookie \(key) is missing or not a string")
    }
    return value
  }

  private static func requiredBool(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> Bool {
    guard case .bool(let value)? = object[key] else {
      throw ObscuraError.protocolViolation("cookie \(key) is missing or not a boolean")
    }
    return value
  }

  private static func normalizeDomain(_ domain: String) -> String {
    String(domain.drop(while: { $0 == "." })).lowercased()
  }
}
