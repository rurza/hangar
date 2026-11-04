import Foundation
import HangarAppStoreConnect
import HangarCore

/// Everything a post-action may use: what was built, where it lives, and the seams for processes, App Store Connect,
/// time and logging. `appStoreConnect` and `key` are nil when the app has no credentials configured.
public struct PostActionContext: Sendable {
    public var app: App
    public var action: ArchiveAction
    public var buildNumber: Int
    public var archivePath: String
    /// Set when the export step wrote an artifact to disk (not for destination `upload`).
    public var exportedArtifactPath: String?
    public var repository: String
    /// The project's directory relative to `repository`; `.` when it sits at the root.
    public var projectDirectory: String
    public var environment: [String: String]
    public var layout: WorkspaceLayout
    public var developerDir: String
    /// The workflow's `team:`; passed to the upload's export options.
    public var teamID: String?
    public var key: ASCKeyArguments?
    public var appStoreConnect: (any AppStoreConnectClient)?
    public var runner: any ProcessRunner
    public var clock: any Clock<Duration>
    public var log: @Sendable (String) -> Void

    public init(
        app: App, action: ArchiveAction, buildNumber: Int, archivePath: String, exportedArtifactPath: String?,
        repository: String, projectDirectory: String, environment: [String: String], layout: WorkspaceLayout,
        developerDir: String, teamID: String?, key: ASCKeyArguments?, appStoreConnect: (any AppStoreConnectClient)?,
        runner: any ProcessRunner, clock: any Clock<Duration>, log: @escaping @Sendable (String) -> Void
    ) {
        self.app = app
        self.action = action
        self.buildNumber = buildNumber
        self.archivePath = archivePath
        self.exportedArtifactPath = exportedArtifactPath
        self.repository = repository
        self.projectDirectory = projectDirectory
        self.environment = environment
        self.layout = layout
        self.developerDir = developerDir
        self.teamID = teamID
        self.key = key
        self.appStoreConnect = appStoreConnect
        self.runner = runner
        self.clock = clock
        self.log = log
    }
}

public struct PostActionOutput: Sendable, Equatable {
    /// One line for the build page.
    public var summary: String
    /// Named values later steps and the UI can read, such as `testflight.buildID`.
    public var outputs: [String: String]

    public init(summary: String, outputs: [String: String] = [:]) {
        self.summary = summary
        self.outputs = outputs
    }
}

/// The contributor-facing interface of a post-action: its settings type parses the YAML, the module does the work.
public protocol PostActionModule: Sendable {
    associatedtype Settings: PostActionSettings
    init(settings: Settings)
    func run(_ context: PostActionContext) async throws -> PostActionOutput
}

/// A module with its settings type erased, so a workflow's actions can be held in one list.
public protocol AnyPostAction: Sendable {
    var name: String { get }
    func run(_ context: PostActionContext) async throws -> PostActionOutput
}

public enum PostActionError: Error, Equatable, CustomStringConvertible {
    case unknownAction(name: String)

    public var description: String {
        switch self {
        case .unknownAction(let name): "unknown post-action '\(name)'"
        }
    }
}

private struct ErasedPostAction<Module: PostActionModule>: AnyPostAction {
    let module: Module
    var name: String { Module.Settings.actionName }

    func run(_ context: PostActionContext) async throws -> PostActionOutput {
        try await module.run(context)
    }
}

public enum PostActionRegistry {
    /// Each entry builds one module from a spec's settings. Phase 2 adds `script`; Phase 4 `upload` and `sparkle-appcast`.
    private static let factories: [String: @Sendable (PostActionSpec) throws -> any AnyPostAction] = [
        TestFlightSettings.actionName: { try make(TestFlightAction.self, $0) }
    ]

    public static func make(_ spec: PostActionSpec) throws -> any AnyPostAction {
        guard let factory = factories[spec.name] else { throw PostActionError.unknownAction(name: spec.name) }
        return try factory(spec)
    }

    private static func make<Module: PostActionModule>(_: Module.Type, _ spec: PostActionSpec) throws -> any AnyPostAction {
        ErasedPostAction(module: Module(settings: try Module.Settings(settings: spec.settings)))
    }
}
