import Foundation

public enum BuildStatus: String, Codable, Sendable {
    case queued, running, succeeded, failed, cancelled

    /// Build status from its jobs: any running/assigned → running; else any queued → queued;
    /// else all succeeded → succeeded; else any failed → failed; else cancelled.
    public static func derived(from jobs: [JobStatus]) -> BuildStatus {
        if jobs.contains(where: { $0 == .running || $0 == .assigned }) { return .running }
        if jobs.contains(.queued) { return .queued }
        if jobs.allSatisfy({ $0 == .succeeded }) { return .succeeded }
        if jobs.contains(.failed) { return .failed }
        return .cancelled
    }
}

public struct Build: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var appID: UUID
    public var workflow: String
    public var ref: String
    public var commit: String
    public var buildNumber: Int
    public var status: BuildStatus
    public var pinnedMachineID: UUID?
    public var createdAt: Date
    public var finishedAt: Date?
    public var jobs: [Job]

    public init(
        id: UUID, appID: UUID, workflow: String, ref: String, commit: String, buildNumber: Int,
        status: BuildStatus, pinnedMachineID: UUID? = nil, createdAt: Date, finishedAt: Date? = nil,
        jobs: [Job] = []
    ) {
        self.id = id
        self.appID = appID
        self.workflow = workflow
        self.ref = ref
        self.commit = commit
        self.buildNumber = buildNumber
        self.status = status
        self.pinnedMachineID = pinnedMachineID
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.jobs = jobs
    }
}
