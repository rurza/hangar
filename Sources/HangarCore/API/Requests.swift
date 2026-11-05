import Foundation

public struct DeployRequest: Codable, Equatable, Sendable {
    public var app: String
    public var workflow: String
    public var ref: String
    public var machine: String?

    public init(app: String, workflow: String, ref: String, machine: String? = nil) {
        self.app = app
        self.workflow = workflow
        self.ref = ref
        self.machine = machine
    }
}

public struct CreateAppRequest: Codable, Equatable, Sendable {
    public var name: String
    public var repoURL: String
    public var appStoreConnectAppID: String
    public var iconURL: String?

    public init(name: String, repoURL: String, appStoreConnectAppID: String, iconURL: String? = nil) {
        self.name = name
        self.repoURL = repoURL
        self.appStoreConnectAppID = appStoreConnectAppID
        self.iconURL = iconURL
    }
}

public struct CreateMachineRequest: Codable, Equatable, Sendable {
    public var name: String
    public var maxConcurrentJobs: Int

    public init(name: String, maxConcurrentJobs: Int = 1) {
        self.name = name
        self.maxConcurrentJobs = maxConcurrentJobs
    }
}

public struct CreateMachineResponse: Codable, Equatable, Sendable {
    public var machine: Machine
    public var token: String

    public init(machine: Machine, token: String) {
        self.machine = machine
        self.token = token
    }
}

/// A one-time code that enrolls a new machine (`POST /machines/pairings`): `XXXX-XXXX`, valid until `expiresAt`,
/// which is `expiresIn` seconds after the server made it (clients count down from that, not their own clock).
public struct Pairing: Codable, Equatable, Sendable {
    public var code: String
    public var expiresAt: Date
    public var expiresIn: Int

    public init(code: String, expiresAt: Date, expiresIn: Int) {
        self.code = code
        self.expiresAt = expiresAt
        self.expiresIn = expiresIn
    }
}

/// `POST /enroll`: creates the machine like `POST /machines`, authorized by a pairing code instead of the UI.
public struct EnrollRequest: Codable, Equatable, Sendable {
    public var code: String
    public var name: String
    /// Default 1.
    public var maxConcurrentJobs: Int?

    public init(code: String, name: String, maxConcurrentJobs: Int? = nil) {
        self.code = code
        self.name = name
        self.maxConcurrentJobs = maxConcurrentJobs
    }
}

public struct BumpNumberRequest: Codable, Equatable, Sendable {
    public var next: Int

    public init(next: Int) { self.next = next }
}

/// A Swift error and the JSON error body `{ "code", "message" }`.
public struct APIError: Error, Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// The SSE payload of `/events`. JSON form: `{"type": "build", "build": {...}}`
/// (likewise `job`, `machine`); `eventName` is the SSE `event:` field.
public enum ServerEvent: Codable, Equatable, Sendable {
    case build(Build)
    case job(Job)
    case machine(Machine)

    public var eventName: String {
        switch self {
        case .build: "build"
        case .job: "job"
        case .machine: "machine"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, build, job, machine }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "build": self = .build(try container.decode(Build.self, forKey: .build))
        case "job": self = .job(try container.decode(Job.self, forKey: .job))
        case "machine": self = .machine(try container.decode(Machine.self, forKey: .machine))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown event type '\(other)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventName, forKey: .type)
        switch self {
        case .build(let build): try container.encode(build, forKey: .build)
        case .job(let job): try container.encode(job, forKey: .job)
        case .machine(let machine): try container.encode(machine, forKey: .machine)
        }
    }
}

/// Where an app's workflow file comes from: defined in Hangar, or `.hangar.yml` in the repository.
public enum WorkflowSource: String, Codable, Sendable { case hangar, repository }

/// `GET /apps/{id}/workflows?ref=`: the workflow file in effect at the commit `ref` resolves to.
public struct WorkflowsResponse: Codable, Equatable, Sendable {
    public var commit: String
    public var workflows: WorkflowFile
    public var source: WorkflowSource

    public init(commit: String, workflows: WorkflowFile, source: WorkflowSource) {
        self.commit = commit
        self.workflows = workflows
        self.source = source
    }
}

/// `GET` and `PUT /apps/{id}/workflow-file`: the YAML defined in Hangar with its parsed form.
public struct StoredWorkflowFile: Codable, Equatable, Sendable {
    public var yaml: String
    public var workflows: WorkflowFile
    public var updatedAt: Date

    public init(yaml: String, workflows: WorkflowFile, updatedAt: Date) {
        self.yaml = yaml
        self.workflows = workflows
        self.updatedAt = updatedAt
    }
}

public struct PutWorkflowFileRequest: Codable, Sendable {
    public var yaml: String

    public init(yaml: String) { self.yaml = yaml }
}

public struct ArtifactInfo: Codable, Equatable, Sendable {
    public var name: String
    public var sizeBytes: Int

    public init(name: String, sizeBytes: Int) {
        self.name = name
        self.sizeBytes = sizeBytes
    }
}

public struct HealthResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var version: String

    public init(ok: Bool, version: String) {
        self.ok = ok
        self.version = version
    }
}

/// What the Settings page shows: which credentials exist, never their secret values.
public struct SettingsStatus: Codable, Equatable, Sendable {
    public var version: String
    /// Nil unless the key ID and the key are set; the issuer ID is optional (none means an individual key).
    public var appStoreConnect: ASCKeyStatus?
    public var githubTokenSet: Bool
    /// True when the server has a `hangar-worker` binary to hand out at `GET /install/hangar-worker`, so the
    /// one-command install (`curl …/install | sh`) works.
    public var workerInstallAvailable: Bool
    /// The GitHub token's account and where it came from; nil without a token.
    public var github: GitHubStatus?

    public init(
        version: String, appStoreConnect: ASCKeyStatus?, githubTokenSet: Bool, workerInstallAvailable: Bool = false,
        github: GitHubStatus? = nil
    ) {
        self.version = version
        self.appStoreConnect = appStoreConnect
        self.githubTokenSet = githubTokenSet
        self.workerInstallAvailable = workerInstallAvailable
        self.github = github
    }

    private enum CodingKeys: String, CodingKey { case version, appStoreConnect, githubTokenSet, workerInstallAvailable, github }

    /// An older server sends no `workerInstallAvailable` (read as false) and no `github`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        appStoreConnect = try container.decodeIfPresent(ASCKeyStatus.self, forKey: .appStoreConnect)
        githubTokenSet = try container.decode(Bool.self, forKey: .githubTokenSet)
        workerInstallAvailable = try container.decodeIfPresent(Bool.self, forKey: .workerInstallAvailable) ?? false
        github = try container.decodeIfPresent(GitHubStatus.self, forKey: .github)
    }
}

/// The identifiers of the configured App Store Connect key; the key itself is never returned.
public struct ASCKeyStatus: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Has an issuer ID; xcodebuild can sign with it.
        case team
        /// No issuer ID; xcodebuild signs with the Xcode account on the worker instead.
        case individual
    }

    public var keyID: String
    /// Nil for an individual key.
    public var issuerID: String?
    public var kind: Kind

    /// `kind` follows from the issuer ID.
    public init(keyID: String, issuerID: String?) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.kind = issuerID == nil ? .individual : .team
    }
}

/// An App Store Connect app, for the "Add app" picker.
public struct ASCAppSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bundleID: String
    /// An app with this App Store Connect ID already exists in Hangar.
    public var registered: Bool
    /// The app's icon (https), when App Store Connect or the iTunes lookup has one.
    public var iconURL: String?

    public init(id: String, name: String, bundleID: String, registered: Bool, iconURL: String? = nil) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.registered = registered
        self.iconURL = iconURL
    }
}

/// `GET /apps/{id}/beta-groups`: a TestFlight group of the app in App Store Connect.
public struct BetaGroup: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Internal groups hold App Store Connect users of the team; external ones need beta review.
    public var isInternal: Bool

    public init(id: String, name: String, isInternal: Bool) {
        self.id = id
        self.name = name
        self.isInternal = isInternal
    }
}

/// `POST /apps/{id}/beta-groups`: creates a TestFlight group named `name`. `isInternal` nil means an internal group,
/// the one a request from before external groups could be created sends.
public struct CreateBetaGroupRequest: Codable, Equatable, Sendable {
    public var name: String
    /// False creates an external group, which needs Beta App Review before its testers get a build.
    public var isInternal: Bool?

    public init(name: String, isInternal: Bool? = nil) {
        self.name = name
        self.isInternal = isInternal
    }
}
