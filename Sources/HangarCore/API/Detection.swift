import Foundation

/// `GET /github/repos`: a repository the global GitHub token can see, for the "Add app" repository picker.
public struct GitHubRepo: Codable, Equatable, Sendable {
    /// `owner/name`.
    public var fullName: String
    public var htmlURL: String
    public var isPrivate: Bool
    public var defaultBranch: String
    public var description: String?
    public var pushedAt: Date?
    public var archived: Bool

    public init(
        fullName: String, htmlURL: String, isPrivate: Bool, defaultBranch: String, description: String? = nil,
        pushedAt: Date? = nil, archived: Bool = false
    ) {
        self.fullName = fullName
        self.htmlURL = htmlURL
        self.isPrivate = isPrivate
        self.defaultBranch = defaultBranch
        self.description = description
        self.pushedAt = pushedAt
        self.archived = archived
    }
}

/// A scheme found in the repository: a shared `.xcscheme`, or one XcodeGen generates.
public struct DetectedScheme: Codable, Equatable, Sendable {
    public var name: String
    /// Nil when the platform could not be worked out.
    public var platform: Platform?
    /// It builds an app (not tests, a framework or an extension), so it can be archived and uploaded.
    public var isApplication: Bool

    public init(name: String, platform: Platform?, isApplication: Bool) {
        self.name = name
        self.platform = platform
        self.isApplication = isApplication
    }
}

/// Where the app's icon lives in the repository.
public struct DetectedIcon: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// `path` is a flat image (from an `.appiconset`) that `GET /apps/{id}/repo-icon` serves.
        case appiconset
        /// `path` is an Icon Composer `.icon` bundle, which only a build can render.
        case iconcomposer
    }

    /// Path in the repository: the image for `appiconset`, the `.icon` bundle for `iconcomposer`.
    public var path: String
    public var kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// `GET /apps/{id}/workflow-suggestion`: a workflow file worked out from the repository at `commit`.
public struct WorkflowSuggestion: Codable, Equatable, Sendable {
    public var commit: String
    /// `.hangar.yml` text; parses with `WorkflowFileParser` to `workflows`.
    public var yaml: String
    /// What was guessed and what to check, one sentence each.
    public var notes: [String]
    public var workflows: WorkflowFile
    /// Every scheme found, sorted by name, the ones not chosen included.
    public var schemes: [DetectedScheme]
    public var icon: DetectedIcon?
    /// The repository has its own `.hangar.yml`, which builds use unless a workflow is defined in Hangar.
    public var hasWorkflowFile: Bool

    public init(
        commit: String, yaml: String, notes: [String], workflows: WorkflowFile, schemes: [DetectedScheme],
        icon: DetectedIcon?, hasWorkflowFile: Bool = false
    ) {
        self.commit = commit
        self.yaml = yaml
        self.notes = notes
        self.workflows = workflows
        self.schemes = schemes
        self.icon = icon
        self.hasWorkflowFile = hasWorkflowFile
    }
}

/// A repository's file listing at a commit: every file and directory path, relative to the root.
public struct RepositoryTree: Equatable, Sendable {
    public var paths: [String]
    /// The host left entries out (a very large repository).
    public var truncated: Bool
    /// Byte sizes of the files (blobs) the host reported; directories have none.
    public var sizes: [String: Int]

    public init(paths: [String], truncated: Bool = false, sizes: [String: Int] = [:]) {
        self.paths = paths
        self.truncated = truncated
        self.sizes = sizes
    }

    /// The repository has a `.hangar.yml` at its root.
    public var hasWorkflowFile: Bool { paths.contains(WorkflowFile.path) }
}

/// An app the repository builds: one or more application targets sharing a bundle ID (one per platform, say).
public struct DetectedApp: Codable, Equatable, Sendable {
    /// The App Store Connect name when matched, else the first target's name.
    public var name: String
    /// Resolved `PRODUCT_BUNDLE_IDENTIFIER`s of its targets; ones built from settings Hangar cannot see are left out.
    public var bundleIDs: [String]
    public var platforms: [Platform]
    /// The schemes that build it.
    public var schemes: [DetectedScheme]
    public var icon: DetectedIcon?
    /// The App Store Connect app with one of `bundleIDs`; nil when none matched or no key is configured.
    public var appStoreConnect: ASCAppSummary?

    public init(
        name: String, bundleIDs: [String], platforms: [Platform], schemes: [DetectedScheme], icon: DetectedIcon?,
        appStoreConnect: ASCAppSummary? = nil
    ) {
        self.name = name
        self.bundleIDs = bundleIDs
        self.platforms = platforms
        self.schemes = schemes
        self.icon = icon
        self.appStoreConnect = appStoreConnect
    }
}

/// `GET /github/repos/{owner}/{repo}/inspect`: the apps a repository builds, before it is added to Hangar.
public struct RepositoryInspection: Codable, Equatable, Sendable {
    public var commit: String
    public var apps: [DetectedApp]
    /// Every workspace and project found (an XcodeGen project as the path it generates), the chosen one first.
    public var projects: [String]
    public var notes: [String]
    /// The repository has its own `.hangar.yml`.
    public var hasWorkflowFile: Bool
    /// App Store Connect is configured but could not be asked, so `appStoreConnect` is nil on every app
    /// whether or not it exists there; `appStoreConnectError` says why.
    public var appStoreConnectUnavailable: Bool
    public var appStoreConnectError: String?

    public init(
        commit: String, apps: [DetectedApp], projects: [String], notes: [String], hasWorkflowFile: Bool = false,
        appStoreConnectUnavailable: Bool = false, appStoreConnectError: String? = nil
    ) {
        self.commit = commit
        self.apps = apps
        self.projects = projects
        self.notes = notes
        self.hasWorkflowFile = hasWorkflowFile
        self.appStoreConnectUnavailable = appStoreConnectUnavailable
        self.appStoreConnectError = appStoreConnectError
    }
}
