import Foundation
import HangarCore
import Logging
import Synchronization

/// How long build logs and artifacts stay. Build history in the database stays whatever happens to the files.
public struct RetentionPolicy: Sendable, Equatable, Codable {
    /// Each app's latest builds keep their files however old they are...
    public var keepBuildsPerApp: Int
    /// ...and so does every build that finished this recently...
    public var keepDays: Int
    /// ...while all build files together stay under this: past it the oldest builds go first, each app's latest
    /// finished one last of all, and a build that has not finished never.
    public var maxGB: Double

    public static let standard = RetentionPolicy(keepBuildsPerApp: 5, keepDays: 7, maxGB: 10)

    public init(keepBuildsPerApp: Int, keepDays: Int, maxGB: Double) {
        self.keepBuildsPerApp = keepBuildsPerApp
        self.keepDays = keepDays
        self.maxGB = maxGB
    }
}

/// Deletes the log and artifacts directories (`jobs/<jobID>`) of builds `RetentionPolicy` no longer keeps, and of
/// jobs that no longer exist (their app was deleted), and measures what the server's files take.
public final class RetentionSweeper: Sendable {
    let jobsDirectory: URL
    let builds: BuildRepository
    public let policy: RetentionPolicy
    /// A directory without a job is left this long, in case its job is being written.
    static let orphanGrace: TimeInterval = 3600
    private let latest = Mutex<HangarDiskUsage?>(nil)
    private let logger = Logger(label: "app.hangar.server.retention")

    public init(jobsDirectory: URL, builds: BuildRepository, policy: RetentionPolicy = .standard) {
        self.jobsDirectory = jobsDirectory.standardizedFileURL
        self.builds = builds
        self.policy = policy
    }

    /// What the server's data directory took at the last sweep; nil before the first.
    public var usage: HangarDiskUsage? { latest.withLock { $0 } }

    /// One directory and the build it belongs to; `record` is nil for an orphan.
    struct Entry {
        var name: String
        var path: String
        var bytes: UInt64
        var record: RetentionRecord?
        var modified: Date?
    }

    /// Removes what the policy no longer keeps and logs one line saying what went and how much that freed. Returns
    /// the names of the removed directories.
    @discardableResult
    public func sweep(now: Date) throws -> [String] {
        let root = jobsDirectory.path
        guard FileManager.default.fileExists(atPath: root) else {
            measure(now: now)
            return []
        }
        let records = Dictionary(try builds.retentionRecords().map { ($0.jobID, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [Entry] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: root).sorted() {
            guard let jobID = UUID(uuidString: name) else { continue }
            let path = root + "/" + name
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            entries.append(Entry(name: name, path: path, bytes: DiskUsage.bytes(of: path), record: records[jobID], modified: modified))
        }

        let doomed = Self.expired(entries, policy: policy, now: now)
        var removed: [String] = []
        var labels: [String] = []
        var freed: UInt64 = 0
        var failures: [String] = []
        for entry in entries where doomed.contains(entry.name) {
            do {
                try SafeRemoval.removeItem(atPath: entry.path, within: root)
                removed.append(entry.name)
                freed += entry.bytes
                let label = entry.record.map { "\($0.appSlug) \($0.buildNumber)" } ?? "a deleted app's job"
                if !labels.contains(label) { labels.append(label) }
            } catch {
                failures.append("\(entry.name): \(error)")
            }
        }
        let usage = measure(now: now)
        if !removed.isEmpty || !failures.isEmpty {
            var line = "retention"
            if !removed.isEmpty {
                line += " removed the files of \(labels.joined(separator: ", ")) and freed \(DiskUsage.text(freed))"
            }
            if !failures.isEmpty { line += (removed.isEmpty ? " " : "; ") + "could not remove \(failures.joined(separator: "; "))" }
            let files = usage.parts.first { $0.label == Self.filesLabel }?.gb ?? 0
            line += "; build files use \(DiskUsage.text(UInt64(files * 1_000_000_000))) of \(Self.text(gb: policy.maxGB))"
            logger.notice("\(line)")
        }
        return removed
    }

    static let filesLabel = "Build logs and artifacts"

    /// The directories the policy no longer keeps, by name.
    static func expired(_ entries: [Entry], policy: RetentionPolicy, now: Date) -> Set<String> {
        var doomed = Set<String>()
        // A job that no longer exists.
        for entry in entries where entry.record == nil {
            if let modified = entry.modified, now.timeIntervalSince(modified) > orphanGrace { doomed.insert(entry.name) }
        }
        // Finished builds per app, newest first; a build's jobs share its fate.
        let finished = entries.filter { $0.record?.finished == true }
        let byBuild = Dictionary(grouping: finished) { $0.record!.buildID }
        let buildsByApp = Dictionary(grouping: byBuild.values.map { $0[0].record! }) { $0.appID }
            .mapValues { $0.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) } }
        let cutoff = now.addingTimeInterval(-TimeInterval(policy.keepDays) * 86_400)
        var kept = Set<UUID>()
        var latest = Set<UUID>()
        for builds in buildsByApp.values {
            if let first = builds.first { latest.insert(first.buildID) }
            for (index, build) in builds.enumerated()
            where index < policy.keepBuildsPerApp || (build.finishedAt ?? .distantPast) >= cutoff {
                kept.insert(build.buildID)
            }
        }
        for (buildID, jobs) in byBuild where !kept.contains(buildID) { doomed.formUnion(jobs.map(\.name)) }

        // The cap: everything left counts, unfinished builds included; the oldest finished builds go first.
        var total = entries.filter { !doomed.contains($0.name) }.reduce(UInt64(0)) { $0 + $1.bytes }
        let cap = UInt64(max(policy.maxGB, 0) * 1_000_000_000)
        guard total > cap else { return doomed }
        let candidates = byBuild.filter { kept.contains($0.key) && !latest.contains($0.key) }
            .sorted { ($0.value[0].record!.finishedAt ?? .distantPast) < ($1.value[0].record!.finishedAt ?? .distantPast) }
        for (_, jobs) in candidates where total > cap {
            doomed.formUnion(jobs.map(\.name))
            total -= jobs.reduce(UInt64(0)) { $0 + $1.bytes }
        }
        return doomed
    }

    /// Measures the server's data directory: the jobs' files and everything else (the database, signing).
    @discardableResult
    func measure(now: Date) -> HangarDiskUsage {
        let data = jobsDirectory.deletingLastPathComponent().path
        let total = DiskUsage.bytes(of: data)
        let files = DiskUsage.bytes(of: jobsDirectory.path)
        let parts = [(Self.filesLabel, files), ("Other", total > files ? total - files : 0)]
            .filter { $0.1 >= 1_000_000 }
            .sorted { $0.1 > $1.1 }
            .map { HangarDiskUsage.Part(label: $0.0, gb: DiskUsage.gigabytes($0.1)) }
        let usage = HangarDiskUsage(totalGB: DiskUsage.gigabytes(total), parts: parts, measuredAt: now)
        latest.withLock { $0 = usage }
        return usage
    }

    static func text(gb: Double) -> String { gb == gb.rounded() ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb) }
}
