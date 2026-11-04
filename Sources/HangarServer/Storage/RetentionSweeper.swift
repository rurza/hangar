import Foundation
import HangarCore
import Logging

/// Deletes the log and artifacts directories of old jobs. Database rows stay: build history outlives its files.
public struct RetentionSweeper: Sendable {
    let jobsDirectory: URL
    let builds: BuildRepository
    let retentionDays: Int
    private let logger = Logger(label: "app.hangar.server.retention")

    public init(jobsDirectory: URL, builds: BuildRepository, retentionDays: Int) {
        self.jobsDirectory = jobsDirectory
        self.builds = builds
        self.retentionDays = retentionDays
    }

    /// Removes `jobs/<jobID>` when the job's build finished more than `retentionDays` before `now`, or when no job
    /// has that ID and the directory was last modified before then. Unfinished builds and non-job entries are kept.
    /// Returns the names of the removed directories.
    @discardableResult
    public func sweep(now: Date) throws -> [String] {
        guard FileManager.default.fileExists(atPath: jobsDirectory.path) else { return [] }
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
        var removed: [String] = []
        let entries = try FileManager.default.contentsOfDirectory(
            at: jobsDirectory, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
        for directory in entries {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values.isDirectory == true, let jobID = UUID(uuidString: directory.lastPathComponent) else { continue }
            guard try isExpired(jobID: jobID, modified: values.contentModificationDate, cutoff: cutoff) else { continue }
            do {
                try FileManager.default.removeItem(at: directory)
                removed.append(directory.lastPathComponent)
            } catch {
                logger.warning("could not remove \(directory.path): \(error)")
            }
        }
        return removed
    }

    private func isExpired(jobID: UUID, modified: Date?, cutoff: Date) throws -> Bool {
        guard let job = try builds.job(id: jobID) else {
            // An orphan (its app was deleted, or it never had a row): judged by age alone.
            return modified.map { $0 < cutoff } ?? false
        }
        guard let build = try builds.build(id: job.buildID), let finishedAt = build.finishedAt else { return false }
        switch build.status {
        case .succeeded, .failed, .cancelled: return finishedAt < cutoff
        case .queued, .running: return false
        }
    }
}
