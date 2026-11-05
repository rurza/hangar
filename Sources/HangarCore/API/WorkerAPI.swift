import Foundation

public struct JobAssignment: Codable, Equatable, Sendable {
    public var job: Job
    public var app: App
    public var workflow: Workflow
    /// The workflow's key in `.hangar.yml` (`CI_WORKFLOW`).
    public var workflowName: String
    public var buildNumber: Int
    public var commit: String
    public var ref: String
    public var environment: [EnvEntry]

    public init(
        job: Job, app: App, workflow: Workflow, workflowName: String, buildNumber: Int, commit: String, ref: String,
        environment: [EnvEntry]
    ) {
        self.job = job
        self.app = app
        self.workflow = workflow
        self.workflowName = workflowName
        self.buildNumber = buildNumber
        self.commit = commit
        self.ref = ref
        self.environment = environment
    }
}

public struct HeartbeatRequest: Codable, Equatable, Sendable {
    public var report: MachineReport

    public init(report: MachineReport) { self.report = report }
}

/// The server has a different `hangar-worker` than the one that just heartbeated. `sha256` is the binary
/// `GET /install/hangar-worker` serves. Absent when the worker did not report its own hash, or the two match.
public struct WorkerUpdate: Codable, Equatable, Sendable {
    public var sha256: String

    public init(sha256: String) { self.sha256 = sha256 }
}

public struct HeartbeatResponse: Codable, Equatable, Sendable {
    public var cancelJobIDs: [UUID]
    public var workerUpdate: WorkerUpdate?

    public init(cancelJobIDs: [UUID] = [], workerUpdate: WorkerUpdate? = nil) {
        self.cancelJobIDs = cancelJobIDs
        self.workerUpdate = workerUpdate
    }
}

public struct StepUpdate: Codable, Equatable, Sendable {
    public var name: String
    public var status: StepStatus
    public var at: Date

    public init(name: String, status: StepStatus, at: Date) {
        self.name = name
        self.status = status
        self.at = at
    }
}

public struct LogEntry: Codable, Equatable, Sendable {
    public var t: Date
    public var step: String
    public var line: String

    public init(t: Date, step: String, line: String) {
        self.t = t
        self.step = step
        self.line = line
    }
}

public struct LogBatch: Codable, Equatable, Sendable {
    public var entries: [LogEntry]

    public init(entries: [LogEntry]) { self.entries = entries }
}

public struct JobResult: Codable, Equatable, Sendable {
    public var status: JobStatus
    public var failureReason: String?
    public var outputs: [String: String]

    public init(status: JobStatus, failureReason: String? = nil, outputs: [String: String] = [:]) {
        self.status = status
        self.failureReason = failureReason
        self.outputs = outputs
    }
}
