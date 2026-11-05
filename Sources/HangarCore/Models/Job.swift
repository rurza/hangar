import Foundation

public enum JobStatus: String, Codable, Sendable {
    case queued, assigned, running, succeeded, failed, cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        case .queued, .assigned, .running: false
        }
    }
}

public enum StepStatus: String, Codable, Sendable {
    case pending, running, succeeded, failed, skipped
}

public enum StepName {
    public static let checkout = "checkout"
    public static let postClone = "post-clone"
    public static let preXcodebuild = "pre-xcodebuild"
    public static let archive = "archive"
    public static let test = "test"
    public static let stamp = "stamp"
    public static let export = "export"
    public static let postXcodebuild = "post-xcodebuild"
    public static let uploadArtifacts = "upload-artifacts"
    public static let cleanup = "cleanup"

    /// `"post-action:testflight"` for `"testflight"`.
    public static func postAction(_ name: String) -> String { "post-action:\(name)" }

    /// Every step a job of `action` reports, in order. Test jobs have no stamp, export or post-actions.
    public static func sequence(for action: WorkflowAction, postActions: [String]) -> [String] {
        switch action.kind {
        case .archive:
            [checkout, postClone, preXcodebuild, archive, stamp, export, postXcodebuild]
                + postActions.map(postAction) + [uploadArtifacts, cleanup]
        case .test:
            [checkout, postClone, preXcodebuild, test, postXcodebuild, uploadArtifacts, cleanup]
        }
    }
}

public struct StepRecord: Codable, Equatable, Sendable {
    public var name: String
    public var status: StepStatus
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(name: String, status: StepStatus, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.name = name
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct Job: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var buildID: UUID
    public var action: WorkflowAction
    public var status: JobStatus
    public var machineID: UUID?
    public var steps: [StepRecord]
    public var queueNote: String?
    public var failureReason: String?
    public var outputs: [String: String]
    public var createdAt: Date
    public var assignedAt: Date?
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: UUID, buildID: UUID, action: WorkflowAction, status: JobStatus, machineID: UUID? = nil,
        steps: [StepRecord] = [], queueNote: String? = nil, failureReason: String? = nil,
        outputs: [String: String] = [:], createdAt: Date, assignedAt: Date? = nil,
        startedAt: Date? = nil, finishedAt: Date? = nil
    ) {
        self.id = id
        self.buildID = buildID
        self.action = action
        self.status = status
        self.machineID = machineID
        self.steps = steps
        self.queueNote = queueNote
        self.failureReason = failureReason
        self.outputs = outputs
        self.createdAt = createdAt
        self.assignedAt = assignedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
