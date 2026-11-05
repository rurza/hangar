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
    /// `warning`: the step did its main work but something after it went wrong without failing the job (a TestFlight
    /// upload whose group assignment App Store Connect refused). `cancelled`: the job was stopped while the step ran.
    case pending, running, succeeded, failed, skipped, warning, cancelled

    /// The step will not change any more.
    public var isFinished: Bool {
        switch self {
        case .succeeded, .failed, .skipped, .warning, .cancelled: true
        case .pending, .running: false
        }
    }
}

/// One stage of a step that reports its progress in parts, such as a TestFlight upload: "Uploaded", "Processed",
/// "Groups", "Beta review". `detail` says what happened ("Internal gets every build automatically", or the reason it
/// failed).
public struct StepStage: Codable, Equatable, Sendable {
    public var name: String
    public var status: StepStatus
    public var detail: String?

    public init(name: String, status: StepStatus, detail: String? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
    }
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
    /// One line for the step's header: why it failed (the first error its log shows), or its warnings.
    public var detail: String?
    /// The step's stages, for a step that reports them; nil otherwise.
    public var stages: [StepStage]?

    public init(
        name: String, status: StepStatus, startedAt: Date? = nil, finishedAt: Date? = nil, detail: String? = nil,
        stages: [StepStage]? = nil
    ) {
        self.name = name
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.detail = detail
        self.stages = stages
    }
}

/// Who ran a job, for its header: the machine (kept by name, so it survives the machine's removal), the worker build
/// and the Xcode the job picked. Every field is filled in as it becomes known.
public struct JobRunInfo: Codable, Equatable, Sendable {
    public var machineName: String?
    /// `HangarVersion.current` and the start of the worker binary's SHA-256: "0.5.0 (a1c9b45d)".
    public var workerVersion: String?
    /// "27.2".
    public var xcodeVersion: String?
    /// "27B48".
    public var xcodeBuild: String?

    public init(machineName: String? = nil, workerVersion: String? = nil, xcodeVersion: String? = nil, xcodeBuild: String? = nil) {
        self.machineName = machineName
        self.workerVersion = workerVersion
        self.xcodeVersion = xcodeVersion
        self.xcodeBuild = xcodeBuild
    }

    /// `self` with every field `other` sets taken from it.
    public func merging(_ other: JobRunInfo) -> JobRunInfo {
        JobRunInfo(
            machineName: other.machineName ?? machineName, workerVersion: other.workerVersion ?? workerVersion,
            xcodeVersion: other.xcodeVersion ?? xcodeVersion, xcodeBuild: other.xcodeBuild ?? xcodeBuild)
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
    /// Nil until a machine starts the job.
    public var runInfo: JobRunInfo?

    public init(
        id: UUID, buildID: UUID, action: WorkflowAction, status: JobStatus, machineID: UUID? = nil,
        steps: [StepRecord] = [], queueNote: String? = nil, failureReason: String? = nil,
        outputs: [String: String] = [:], createdAt: Date, assignedAt: Date? = nil,
        startedAt: Date? = nil, finishedAt: Date? = nil, runInfo: JobRunInfo? = nil
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
        self.runInfo = runInfo
    }
}
