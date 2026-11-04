public enum Platform: String, Codable, Sendable, CaseIterable {
    case iOS = "ios", macOS = "macos", visionOS = "visionos", tvOS = "tvos", watchOS = "watchos"

    public var ciName: String {
        switch self {
        case .iOS: "iOS"
        case .macOS: "macOS"
        case .visionOS: "visionOS"
        case .tvOS: "tvOS"
        case .watchOS: "watchOS"
        }
    }

    public var genericDestination: String { "generic/platform=\(ciName)" }

    public var appStoreConnectPlatform: String {
        switch self {
        case .iOS: "IOS"
        case .macOS: "MAC_OS"
        case .visionOS: "VISION_OS"
        case .tvOS: "TV_OS"
        case .watchOS: "WATCH_OS"
        }
    }
}

public enum ExportMethod: String, Codable, Sendable {
    case appStoreConnect = "app-store-connect"
    case developerID = "developer-id"
}

public struct ArchiveAction: Codable, Hashable, Sendable {
    public var scheme: String
    public var platform: Platform
    public var export: ExportMethod

    public init(scheme: String, platform: Platform, export: ExportMethod) {
        self.scheme = scheme
        self.platform = platform
        self.export = export
    }
}

public struct PostActionSpec: Codable, Equatable, Sendable {
    public var name: String
    public var settings: [String: JSONValue]
    public var requiresApproval: Bool

    public init(name: String, settings: [String: JSONValue] = [:], requiresApproval: Bool = false) {
        self.name = name
        self.settings = settings
        self.requiresApproval = requiresApproval
    }
}

public struct Workflow: Codable, Equatable, Sendable {
    public var project: String?
    public var workspace: String?
    public var xcode: String
    public var teamID: String?
    public var tools: [String]
    public var actions: [ArchiveAction]
    public var postActions: [PostActionSpec]

    public init(
        project: String? = nil, workspace: String? = nil, xcode: String, teamID: String? = nil,
        tools: [String] = [], actions: [ArchiveAction], postActions: [PostActionSpec] = []
    ) {
        self.project = project
        self.workspace = workspace
        self.xcode = xcode
        self.teamID = teamID
        self.tools = tools
        self.actions = actions
        self.postActions = postActions
    }

    /// Path of the project or workspace, relative to the repository root.
    public var projectOrWorkspacePath: String { project ?? workspace ?? "" }

    /// Directory holding the project or workspace (`.` at the repository root).
    public var projectDirectory: String {
        guard let slash = projectOrWorkspacePath.lastIndex(of: "/") else { return "." }
        let directory = String(projectOrWorkspacePath[..<slash])
        return directory.isEmpty ? "/" : directory
    }
}

public struct WorkflowFile: Codable, Equatable, Sendable {
    public static let path = ".hangar.yml"
    public var version: Int
    public var workflows: [String: Workflow]

    public init(version: Int, workflows: [String: Workflow]) {
        self.version = version
        self.workflows = workflows
    }
}

public enum WorkflowFileError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidYAML(String)
    case unsupportedVersion(Int)
    case noWorkflows
    case projectAndWorkspace(workflow: String)
    case noProject(workflow: String)
    case noActions(workflow: String)
    case unknownPlatform(String)
    case unknownExportMethod(String)
    case unknownPostAction(name: String, workflow: String)
    case invalidPostActionSettings(name: String, reason: String)

    public var description: String {
        switch self {
        case .invalidYAML(let message): ".hangar.yml is not valid: \(message)"
        case .unsupportedVersion(let version): ".hangar.yml version \(version) is not supported (expected 1)"
        case .noWorkflows: ".hangar.yml defines no workflows"
        case .projectAndWorkspace(let workflow): "workflow '\(workflow)' sets both project and workspace; use exactly one"
        case .noProject(let workflow): "workflow '\(workflow)' needs a project or a workspace"
        case .noActions(let workflow): "workflow '\(workflow)' has no actions"
        case .unknownPlatform(let name): "unknown platform '\(name)'"
        case .unknownExportMethod(let name): "unknown export method '\(name)'"
        case .unknownPostAction(let name, let workflow): "workflow '\(workflow)' uses unknown post-action '\(name)'"
        case .invalidPostActionSettings(let name, let reason): "invalid settings for post-action '\(name)': \(reason)"
        }
    }
}
