import Foundation

/// Where a job's files live under the worker data directory. Pure path computation; nothing here touches the disk.
public struct WorkspaceLayout: Sendable, Equatable {
    private let workspace: String
    public let jobDirectory: String
    /// The directory holding every job's `TMPDIR`, one folder per job ID.
    public let temporaryRoot: String
    private let jobID: UUID

    /// `hangar-jobs` in the per-user system temp directory (`confstr(_CS_DARWIN_USER_TEMP_DIR)`, e.g.
    /// `/var/folders/xx/yyyy/T/`): short and without spaces, unlike the data directory under "Application Support",
    /// where Xcode's universal archive fails to find the dSYM files it writes to `TMPDIR`.
    public static var systemTemporaryRoot: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        var base = NSTemporaryDirectory()
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            base = String(cString: buffer)
        }
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        return base + "/hangar-jobs"
    }

    public init(dataDirectory: String, appSlug: String, jobID: UUID, temporaryRoot: String = systemTemporaryRoot) {
        self.jobID = jobID
        self.temporaryRoot = temporaryRoot
        workspace = "\(dataDirectory)/workspaces/\(appSlug)"
        jobDirectory = "\(dataDirectory)/jobs/\(jobID.uuidString)"
    }

    /// The cached per-app git checkout, reused across jobs.
    public var repository: String { "\(workspace)/repository" }
    public var derivedData: String { "\(workspace)/DerivedData" }
    public var secrets: String { "\(jobDirectory)/secrets" }
    public var export: String { "\(jobDirectory)/export" }
    public var upload: String { "\(jobDirectory)/upload" }
    public var resultBundle: String { "\(jobDirectory)/result.xcresult" }
    /// The job's `TMPDIR`, outside the job directory: `<temporaryRoot>/<job ID>`.
    public var temporary: String { "\(temporaryRoot)/\(jobID.uuidString)" }

    public func archive(scheme: String) -> String { "\(jobDirectory)/archive/\(scheme).xcarchive" }
}
