import Foundation

/// Where a job's files live under the worker data directory. Pure path computation; nothing here touches the disk.
public struct WorkspaceLayout: Sendable, Equatable {
    private let workspace: String
    public let jobDirectory: String

    public init(dataDirectory: String, appSlug: String, jobID: UUID) {
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

    public func archive(scheme: String) -> String { "\(jobDirectory)/archive/\(scheme).xcarchive" }
}
