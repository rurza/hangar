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

public struct HeartbeatResponse: Codable, Equatable, Sendable {
    public var cancelJobIDs: [UUID]

    public init(cancelJobIDs: [UUID] = []) { self.cancelJobIDs = cancelJobIDs }
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
