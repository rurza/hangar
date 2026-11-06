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
    /// Bearer tokens for agents; only their hashes are stored.
    public let apiTokens: APITokenRepository
    /// Tokens a job's VM uses instead of its machine's; only their hashes are stored.
    public let jobTokens: JobTokenRepository
    public let variables: VariableRepository
    /// The one Apple Development identity VM archives sign with; created or imported only on the owner's request.
    public let signing: SigningIdentityService
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
    /// Each app's branches, for the Deploy sheet.
    public let repositoryBranches: RepositoryBranchesCache
    let appStoreConnectFactory: @Sendable (ASCCredentials) -> any AppStoreConnectClient
    /// What the first-run setup reads from and runs on this Mac.
    let setup: SetupEnvironment
    /// Server-wide settings that are not variables.
    let serverSettings: ServerSettingsRepository
    /// The App Store Connect keys (Settings › App Store Connect): settings, never variables.
    let ascKeys: AppStoreConnectKeyRepository
    /// Whose the GitHub token is.
    let githubAccounts: GitHubAccounts
    let localHostName = LocalHostName()
    /// "Use This Mac for Builds".
    let localWorkerSetup = LocalWorkerSetup()
    /// The deploy check's warnings about the repository's scripts and App Store Connect.
    let preflight: DeployPreflight

    /// `numberSources` replaces the default sources (App Store Connect builds, Xcode Cloud runs, appcast), which
    /// read the stored App Store Connect key on every use so credentials set after start-up take effect. `iconTransport`
    /// carries the public iTunes lookup that finds icons App Store Connect has none for; `githubTransport` the
    /// repository list and the token's account. `setup` is this Mac as the first-run setup sees it. `signingRunner`
    /// runs `/usr/bin/openssl` for the signing identity.
    public init(
        configuration: ServerConfiguration, database: Database,
        appStoreConnectFactory: @escaping @Sendable (ASCCredentials) -> any AppStoreConnectClient,
        sourceHost: any SourceHost = GitHubSourceHost(), clock: any Clock<Duration> = ContinuousClock(),
        numberSources: (@Sendable () async throws -> [any KnownNumberSource])? = nil,
        iconTransport: any HTTPTransport = URLSessionTransport(),
        githubTransport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init, setup: SetupEnvironment = .live(),
        signingRunner: any ProcessRunner = LiveProcessRunner()
    ) throws {
        self.configuration = configuration
        self.database = database
        self.clock = clock
        self.now = now
        self.appStoreConnectFactory = appStoreConnectFactory
        apps = AppRepository(database: database)
        builds = BuildRepository(database: database)
        machines = MachineRepository(database: database)
        apiTokens = APITokenRepository(database: database)
        jobTokens = JobTokenRepository(database: database)
        workflowFiles = WorkflowFileRepository(database: database)
        let box = SecretBox(key: try MasterKey.loadOrCreate(at: configuration.masterKeyPath))
        let variables = VariableRepository(database: database, box: box)
        self.variables = variables
        let ascKeys = AppStoreConnectKeyRepository(database: database, box: box)
        self.ascKeys = ascKeys
        SigningWorkspace.sweep(parent: configuration.dataDirectory)
        let signing = SigningIdentityService(
            repository: SigningIdentityRepository(database: database, box: box),
            crypto: SigningCrypto(runner: signingRunner, workParent: configuration.dataDirectory),
            credentials: { try Self.appStoreConnectCredentials(keys: ascKeys) }, factory: appStoreConnectFactory,
            now: now)
        self.signing = signing
        numbers = BuildNumberService(
            repository: builds,
            sources: numberSources ?? { try Self.defaultNumberSources(keys: ascKeys, factory: appStoreConnectFactory) })
        events = EventBus()
        scheduler = SchedulerLoop(
            builds: builds, machines: machines, events: events,
            config: SchedulerConfig(minFreeDiskGB: configuration.minFreeDiskGB), clock: clock, now: now,
            // An unreadable key counts as a team key: the worker then says what is wrong, instead of every headless
            // machine refusing the job.
            teamKey: { _ in (try? ascKeys.key(.main)).map { $0?.isTeamKey ?? false } ?? true },
            signingProblem: { signing.jobProblem() })
        cancelRequests = CancelRequests()
        buildService = BuildService(
            apps: apps, builds: builds, machines: machines, variables: variables, workflowFiles: workflowFiles,
            numbers: numbers, sourceHost: sourceHost, events: events, scheduler: scheduler, cancelRequests: cancelRequests)
        logStore = LogStore(jobsDirectory: configuration.jobsDirectory)
        artifactStore = ArtifactStore(jobsDirectory: configuration.jobsDirectory)
        sweeper = RetentionSweeper(
            jobsDirectory: configuration.jobsDirectory, builds: builds, retentionDays: configuration.retentionDays)
        appIcons = AppIconResolver(
            client: { try Self.appStoreConnectClient(keys: ascKeys, factory: appStoreConnectFactory) },
            transport: iconTransport, clock: clock, now: now)
        appIconBackfill = AppIconBackfill(resolver: appIcons, apps: apps, now: now)
        pairings = PairingCodes(now: now)
        githubRepositories = GitHubRepositories(transport: githubTransport, now: now)
        repositoryDetector = RepositoryDetector(sourceHost: sourceHost, clock: clock, now: now)
        repositoryWorkflowFiles = RepositoryWorkflowFileCache(now: now)
        repositoryBranches = RepositoryBranchesCache(now: now)
        self.setup = setup
        serverSettings = ServerSettingsRepository(database: database)
        githubAccounts = GitHubAccounts(transport: githubTransport, now: now)
        preflight = DeployPreflight(sourceHost: sourceHost, now: now)
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

    /// The server's App Store Connect credentials (Settings › App Store Connect), nil when no key is stored. No issuer
    /// ID means an individual key.
    static func appStoreConnectCredentials(keys: AppStoreConnectKeyRepository) throws -> ASCCredentials? {
        try keys.key(.main).map { ASCCredentials(keyID: $0.keyID, issuerID: $0.issuerID, privateKeyPEM: $0.privateKey) }
    }

    /// A client for the stored key, nil when there is none. Reads the key on every call.
    func appStoreConnectClient() throws -> (any AppStoreConnectClient)? {
        try Self.appStoreConnectClient(keys: ascKeys, factory: appStoreConnectFactory)
    }

    static func appStoreConnectClient(
        keys: AppStoreConnectKeyRepository, factory: @Sendable (ASCCredentials) -> any AppStoreConnectClient
    ) throws -> (any AppStoreConnectClient)? {
        try appStoreConnectCredentials(keys: keys).map(factory)
    }

    static func defaultNumberSources(
        keys: AppStoreConnectKeyRepository, factory: @Sendable (ASCCredentials) -> any AppStoreConnectClient
    ) throws -> [any KnownNumberSource] {
        guard let client = try appStoreConnectClient(keys: keys, factory: factory) else {
            throw BuildNumberError.appStoreConnectNotConfigured
        }
        return [AppStoreConnectBuildsSource(client: client), XcodeCloudRunsSource(client: client), AppcastSource()]
    }
}
