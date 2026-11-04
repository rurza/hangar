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
    /// Nil unless the key ID, issuer ID and key are all set.
    public var appStoreConnect: ASCKeyStatus?
    public var githubTokenSet: Bool

    public init(version: String, appStoreConnect: ASCKeyStatus?, githubTokenSet: Bool) {
        self.version = version
        self.appStoreConnect = appStoreConnect
        self.githubTokenSet = githubTokenSet
    }
}

/// The identifiers of the configured App Store Connect key; the key itself is never returned.
public struct ASCKeyStatus: Codable, Equatable, Sendable {
    public var keyID: String
    public var issuerID: String

    public init(keyID: String, issuerID: String) {
        self.keyID = keyID
        self.issuerID = issuerID
    }
}

/// An App Store Connect app, for the "Add app" picker.
public struct ASCAppSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bundleID: String
    /// An app with this App Store Connect ID already exists in Hangar.
    public var registered: Bool

    public init(id: String, name: String, bundleID: String, registered: Bool) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.registered = registered
    }
}
