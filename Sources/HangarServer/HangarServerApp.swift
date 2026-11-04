import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird

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
    let appStoreConnectFactory: @Sendable (ASCCredentials) -> any AppStoreConnectClient

    /// `numberSources` replaces the default sources (App Store Connect builds, Xcode Cloud runs, appcast), which
    /// read the `HANGAR_ASC_*` globals on every use so credentials set after start-up take effect.
    public init(
        configuration: ServerConfiguration, database: Database,
        appStoreConnectFactory: @escaping @Sendable (ASCCredentials) -> any AppStoreConnectClient,
        sourceHost: any SourceHost = GitHubSourceHost(), clock: any Clock<Duration> = ContinuousClock(),
        numberSources: (@Sendable () async throws -> [any KnownNumberSource])? = nil,
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
    }

    public func build() -> some ApplicationProtocol {
        Application(
            router: buildRouter(),
            configuration: .init(address: .hostname(configuration.host, port: configuration.port), serverName: "hangar"))
    }

    /// The App Store Connect credentials from the `HANGAR_ASC_*` globals, nil unless all three are set. The key-path
    /// variable holds the `.p8` contents; the worker writes them to a file for xcodebuild.
    static func appStoreConnectCredentials(variables: VariableRepository) throws -> ASCCredentials? {
        func global(_ name: String) throws -> String? {
            try variables.value(global: name).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let keyID = try global("HANGAR_ASC_KEY_ID"), let issuerID = try global("HANGAR_ASC_ISSUER_ID"),
            let privateKey = try global("HANGAR_ASC_KEY_PATH")
        else { return nil }
        return ASCCredentials(keyID: keyID, issuerID: issuerID, privateKeyPEM: privateKey)
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
