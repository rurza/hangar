import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird
import Logging
import NIOCore
import ServiceLifecycle
import UnixSignals

/// The composition root: builds the repositories and services once and exposes them, so the worker routes and the
/// executable's run loop (scheduler, retention sweeper) share them with the public API.
public struct HangarServerApp: Sendable {
    public let configuration: ServerConfiguration
    public let database: Database
    public let clock: any Clock<Duration>
    /// The wall clock for stored timestamps (job start and finish, heartbeats); tests pass a fixed date.
    public let now: @Sendable () -> Date
    public let apps: AppRepository
    public let builds: BuildRepository
    public let machines: MachineRepository
    public let variables: VariableRepository
    public let workflowFiles: WorkflowFileRepository
    public let numbers: BuildNumberService
    public let events: EventBus
    public let scheduler: SchedulerLoop
    public let cancelRequests: CancelRequests
    public let buildService: BuildService
    public let logStore: LogStore
    public let artifactStore: ArtifactStore
    public let sweeper: RetentionSweeper
    public let appIcons: AppIconResolver
    public let appIconBackfill: AppIconBackfill
    /// The one-time codes new Macs enroll with; in memory, so a restart forgets them.
    public let pairings: PairingCodes
    /// The repositories the global GitHub token sees, cached for the "Add app" picker.
    public let githubRepositories: GitHubRepositories
    /// Reads repositories for workflow and app detection.
    public let repositoryDetector: RepositoryDetector
    /// Whether each app's repository has a `.hangar.yml`, for the app page and the workflow editor.
    public let repositoryWorkflowFiles: RepositoryWorkflowFileCache
    let appStoreConnectFactory: @Sendable (ASCCredentials) -> any AppStoreConnectClient

    /// `numberSources` replaces the default sources (App Store Connect builds, Xcode Cloud runs, appcast), which
    /// read the `HANGAR_ASC_*` globals on every use so credentials set after start-up take effect. `iconTransport`
    /// carries the public iTunes lookup that finds icons App Store Connect has none for; `githubTransport` the
    /// repository list.
    public init(
        configuration: ServerConfiguration, database: Database,
        appStoreConnectFactory: @escaping @Sendable (ASCCredentials) -> any AppStoreConnectClient,
        sourceHost: any SourceHost = GitHubSourceHost(), clock: any Clock<Duration> = ContinuousClock(),
        numberSources: (@Sendable () async throws -> [any KnownNumberSource])? = nil,
        iconTransport: any HTTPTransport = URLSessionTransport(),
        githubTransport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.configuration = configuration
        self.database = database
        self.clock = clock
        self.now = now
        self.appStoreConnectFactory = appStoreConnectFactory
        apps = AppRepository(database: database)
        builds = BuildRepository(database: database)
        machines = MachineRepository(database: database)
        workflowFiles = WorkflowFileRepository(database: database)
        let variables = VariableRepository(
            database: database, box: SecretBox(key: try MasterKey.loadOrCreate(at: configuration.masterKeyPath)))
        self.variables = variables
        numbers = BuildNumberService(
            repository: builds,
            sources: numberSources ?? { try Self.defaultNumberSources(variables: variables, factory: appStoreConnectFactory) })
        events = EventBus()
        scheduler = SchedulerLoop(
            builds: builds, machines: machines, events: events,
            config: SchedulerConfig(minFreeDiskGB: configuration.minFreeDiskGB), clock: clock, now: now)
        cancelRequests = CancelRequests()
        buildService = BuildService(
            apps: apps, builds: builds, machines: machines, variables: variables, workflowFiles: workflowFiles,
            numbers: numbers, sourceHost: sourceHost, events: events, scheduler: scheduler, cancelRequests: cancelRequests)
        logStore = LogStore(jobsDirectory: configuration.jobsDirectory)
        artifactStore = ArtifactStore(jobsDirectory: configuration.jobsDirectory)
        sweeper = RetentionSweeper(
            jobsDirectory: configuration.jobsDirectory, builds: builds, retentionDays: configuration.retentionDays)
        appIcons = AppIconResolver(
            client: { try Self.appStoreConnectClient(variables: variables, factory: appStoreConnectFactory) },
            transport: iconTransport, clock: clock, now: now)
        appIconBackfill = AppIconBackfill(resolver: appIcons, apps: apps, now: now)
        pairings = PairingCodes(now: now)
        githubRepositories = GitHubRepositories(transport: githubTransport, now: now)
        repositoryDetector = RepositoryDetector(sourceHost: sourceHost, clock: clock, now: now)
        repositoryWorkflowFiles = RepositoryWorkflowFileCache(now: now)
    }

    /// Starts resolving icons for every app without one (at start-up); returns at once.
    public func backfillAppIcons() throws {
        appIconBackfill.fill(try apps.all())
    }

    /// `onServerRunning` gets the port the server listens on (useful with port 0).
    public func build(onServerRunning: @escaping @Sendable (Int) async -> Void = { _ in }) -> some ApplicationProtocol {
        Application(
            router: buildRouter(),
            configuration: .init(address: .hostname(configuration.host, port: configuration.port), serverName: "hangar"),
            onServerRunning: { channel in await onServerRunning(channel.localAddress?.port ?? 0) })
    }

    /// How long a graceful shutdown may take before the remaining requests are cancelled: a backstop for any
    /// response that does not end by itself, so a launchd restart never stalls.
    public static let maximumGracefulShutdownDuration: Duration = .seconds(5)

    /// The service group that runs `application`: shut down gracefully on `gracefulShutdownSignals`, cancelled
    /// after `maximumGracefulShutdownDuration`.
    public func serviceGroup(
        running application: some Service, gracefulShutdownSignals: [UnixSignal] = [.sigterm, .sigint], logger: Logger
    ) -> ServiceGroup {
        var configuration = ServiceGroupConfiguration(
            services: [application], gracefulShutdownSignals: gracefulShutdownSignals, logger: logger)
        configuration.maximumGracefulShutdownDuration = Self.maximumGracefulShutdownDuration
        return ServiceGroup(configuration: configuration)
    }

    /// The App Store Connect credentials from the `HANGAR_ASC_*` globals, nil unless the key ID and the key are set.
    /// The key-path variable holds the `.p8` contents; the worker writes them to a file for xcodebuild. A missing or
    /// empty `HANGAR_ASC_ISSUER_ID` means an individual key.
    static func appStoreConnectCredentials(variables: VariableRepository) throws -> ASCCredentials? {
        func global(_ name: String) throws -> String? {
            try variables.value(global: name).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let keyID = try global("HANGAR_ASC_KEY_ID"), let privateKey = try global("HANGAR_ASC_KEY_PATH")
        else { return nil }
        return ASCCredentials(keyID: keyID, issuerID: try global("HANGAR_ASC_ISSUER_ID"), privateKeyPEM: privateKey)
    }

    /// A client for the configured key, nil when it is not configured. Reads the globals on every call.
    func appStoreConnectClient() throws -> (any AppStoreConnectClient)? {
        try Self.appStoreConnectClient(variables: variables, factory: appStoreConnectFactory)
    }

    static func appStoreConnectClient(
        variables: VariableRepository, factory: @Sendable (ASCCredentials) -> any AppStoreConnectClient
    ) throws -> (any AppStoreConnectClient)? {
        try appStoreConnectCredentials(variables: variables).map(factory)
    }

    static func defaultNumberSources(
        variables: VariableRepository, factory: @Sendable (ASCCredentials) -> any AppStoreConnectClient
    ) throws -> [any KnownNumberSource] {
        guard let client = try appStoreConnectClient(variables: variables, factory: factory) else {
            throw BuildNumberError.appStoreConnectNotConfigured
        }
        return [AppStoreConnectBuildsSource(client: client), XcodeCloudRunsSource(client: client), AppcastSource()]
    }
}
