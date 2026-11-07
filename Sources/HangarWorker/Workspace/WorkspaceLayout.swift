import Foundation

/// Where a job's files live under the worker's work directory. Pure path computation; nothing here touches the disk.
public struct WorkspaceLayout: Sendable, Equatable {
    public let workspace: String
    public let jobDirectory: String
    /// The directory holding every job's `TMPDIR`, one folder per job ID.
    public let temporaryRoot: String
    private let jobID: UUID

    /// `<work directory>/tmp`: one folder per job, outside the job directory, and like the rest of the work
    /// directory without spaces. Each worker has its own, so sweeping it at start never touches another worker's
    /// running jobs (the per-user system temp directory is shared by every worker on the Mac).
    public static func temporaryRoot(dataDirectory: String) -> String { dataDirectory + "/tmp" }

    /// `dataDirectory` is the worker's work directory (`WorkerConfiguration.resolvedWorkDirectory`).
    public init(dataDirectory: String, appSlug: String, jobID: UUID, temporaryRoot: String? = nil) {
        self.jobID = jobID
        self.temporaryRoot = temporaryRoot ?? Self.temporaryRoot(dataDirectory: dataDirectory)
        workspace = "\(dataDirectory)/workspaces/\(appSlug)"
        jobDirectory = "\(dataDirectory)/jobs/\(jobID.uuidString)"
    }

    /// The cached per-app git checkout, reused across jobs.
    public var repository: String { "\(workspace)/repository" }
    public var derivedData: String { "\(workspace)/DerivedData" }
    public var secrets: String { "\(jobDirectory)/secrets" }
    /// The App Store Connect key's `.p8`, only while a step that uses it runs (`AppStoreConnectKeyFile`).
    public var keyDirectory: String { "\(jobDirectory)/asc-key" }
    public var export: String { "\(jobDirectory)/export" }
    public var upload: String { "\(jobDirectory)/upload" }
    public var resultBundle: String { "\(jobDirectory)/result.xcresult" }
    /// A test job's failed snapshots; collected as `<scheme>-snapshot-failures.zip`.
    public var snapshotArtifacts: String { "\(jobDirectory)/snapshot-artifacts" }
    /// Everything the job logged, uncondensed; see `JobLog`.
    public var fullLog: String { "\(jobDirectory)/full-log.txt" }
    /// The job's `TMPDIR`, outside the job directory: `<temporaryRoot>/<job ID>`.
    public var temporary: String { "\(temporaryRoot)/\(jobID.uuidString)" }

    public func archive(scheme: String) -> String { "\(jobDirectory)/archive/\(scheme).xcarchive" }
}
