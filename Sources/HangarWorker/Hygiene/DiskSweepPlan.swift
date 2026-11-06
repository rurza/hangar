import Foundation
import HangarCore

/// One thing a sweep deletes: `path`, which must be strictly inside `root`, one of Hangar's own directories.
public struct SweepRemoval: Equatable, Sendable {
    /// For the log: "workspace batfi", "VM image xcode-27.1".
    public var label: String
    public var path: String
    public var root: String
    /// Set for a local workspace: removed only while no job holds it (`WorkspaceUse`).
    public var workspace: Bool = false

    public init(label: String, path: String, root: String, workspace: Bool = false) {
        self.label = label
        self.path = path
        self.root = root
        self.workspace = workspace
    }
}

/// What a sweep knows about the moment it runs.
public struct SweepContext: Sendable {
    public var now: Date
    /// Jobs this worker runs: their clones, job and temporary directories stay.
    public var runningJobIDs: Set<UUID>
    /// The Xcode versions the server's queued and running jobs ask for; nil when unknown (before the first heartbeat,
    /// or an older server), and then no job image is removed.
    public var xcodesNeeded: [String]?
    /// The Xcodes installed on this Mac; nil when unknown, and then no job image is removed.
    public var hostXcodes: [InstalledXcode]?

    public init(now: Date, runningJobIDs: Set<UUID> = [], xcodesNeeded: [String]? = nil, hostXcodes: [InstalledXcode]? = nil) {
        self.now = now
        self.runningJobIDs = runningJobIDs
        self.xcodesNeeded = xcodesNeeded
        self.hostXcodes = hostXcodes
    }
}

/// What the disk sweep removes, decided from the disk without changing it. Each rule says why the thing is junk.
public enum DiskSweepPlan {
    /// A Hangar temporary directory not touched for this long is no longer in use.
    public static let temporaryMaxAge: TimeInterval = 86_400
    /// On a Mac that builds on the host, an app's workspace not built for this long goes; its next build clones again.
    public static let workspaceIdleDays = 14

    // MARK: Temporary files

    /// `hangar-*` in the system temporary directory (a doctor's probe, a firewall rule being installed, a staging
    /// folder of an older worker) once nothing in it has changed for a day; and the per-job `TMPDIR`s in
    /// `jobTemporaryRoot` of jobs this worker is not running.
    public static func temporary(systemTemporary: String, jobTemporaryRoot: String, context: SweepContext) -> [SweepRemoval] {
        var removals: [SweepRemoval] = []
        let system = standardized(systemTemporary)
        for name in entries(system) where name.hasPrefix("hangar-") {
            let path = system + "/" + name
            guard let modified = lastModified(tree: path), context.now.timeIntervalSince(modified) > temporaryMaxAge else {
                continue
            }
            removals.append(SweepRemoval(label: "temporary \(name)", path: path, root: system))
        }
        let jobs = standardized(jobTemporaryRoot)
        for name in entries(jobs) where !isRunning(name, context) {
            removals.append(SweepRemoval(label: "job temporary directory \(name)", path: jobs + "/" + name, root: jobs))
        }
        return removals
    }

    // MARK: Workspaces

    /// The cached checkouts under each `workspaces` directory. A Mac with VM builds never uses them: they all go,
    /// with the directory. Otherwise an app's workspace goes once it has not been built here for
    /// `workspaceIdleDays`: its warm caches are worth a fetch instead of a clone only while the app is being built.
    public static func workspaces(
        in workspaceDirectories: [String], vmBuilds: Bool, context: SweepContext, idleDays: Int = workspaceIdleDays
    ) -> [SweepRemoval] {
        var removals: [SweepRemoval] = []
        for directory in Set(workspaceDirectories.map(standardized)).sorted() {
            let parent = (directory as NSString).deletingLastPathComponent
            let names = entries(directory).filter { !$0.hasPrefix(".") }
            if vmBuilds {
                guard FileManager.default.fileExists(atPath: directory) else { continue }
                let label = names.isEmpty ? "the empty workspaces folder" : "host workspaces \(names.joined(separator: ", "))"
                removals.append(SweepRemoval(label: label, path: directory, root: parent))
                continue
            }
            for name in names {
                let path = directory + "/" + name
                guard isDirectory(path), let built = lastBuilt(workspace: path),
                    context.now.timeIntervalSince(built) > TimeInterval(idleDays) * 86_400
                else { continue }
                removals.append(SweepRemoval(label: "workspace \(name)", path: path, root: directory, workspace: true))
            }
        }
        return removals
    }

    /// When the workspace was last built: its marker, else (a workspace from before markers) the latest of the
    /// workspace's own folder and its checkout's git state.
    static func lastBuilt(workspace: String) -> Date? {
        if let marked = modified(workspace + "/" + WorkspaceUse.markerName) { return marked }
        let candidates = [workspace, workspace + "/repository/.git/FETCH_HEAD", workspace + "/repository/.git/HEAD",
            workspace + "/repository/.git/index", workspace + "/DerivedData"]
        return candidates.compactMap(modified).max()
    }

    // MARK: VM storage

    /// Leftovers in VM storage:
    /// - a job clone of a job this worker is not running;
    /// - a partial image whose import or build ended without finishing (`VMPartialLock`);
    /// - a slot beyond `settings.slots`, or any slot of an image that is not a job image;
    /// - a job image whose Xcode is no longer on this Mac, once a newer job image exists. Never the newest, never one
    ///   a queued or running job's Xcode request picks, and only when both are known;
    /// - a base (vanilla) image once a newer one exists, unless an image is being built. The newest base stays: a job
    ///   image is a clone of it, so it costs only the blocks the build changed (2 GB on the MacBook), while getting it
    ///   again is a 25 GB download.
    public static func vmStorage(_ storage: VMStorage, settings: VMSettings, context: SweepContext) -> [SweepRemoval] {
        var removals: [SweepRemoval] = []
        for name in entries(storage.jobs) where !isRunning(name, context) {
            removals.append(SweepRemoval(label: "VM clone \(name)", path: storage.jobs + "/" + name, root: storage.jobs))
        }
        let names = entries(storage.images)
        var building = false
        for name in names where name.hasPrefix(VMStorage.partialPrefix) {
            let path = storage.images + "/" + name
            if VMPartialLock.isAbandoned(path, now: context.now) {
                let image = String(name.dropFirst(VMStorage.partialPrefix.count))
                removals.append(SweepRemoval(label: "unfinished VM image \(image)", path: path, root: storage.images))
            } else {
                building = true
            }
        }
        let images = storage.imageNames().compactMap { try? VMImage(directory: storage.image($0)) }
        for image in images {
            let slots = image.directory.slots
            for name in entries(slots) where !name.hasPrefix(".") {
                let keep = image.metadata.isJobImage && Int(name).map { (0..<settings.slots).contains($0) } == true
                if !keep {
                    removals.append(SweepRemoval(
                        label: "slot \(name) of \(image.metadata.name)", path: slots + "/" + name, root: slots))
                }
            }
        }
        removals += staleJobImages(images.filter(\.metadata.isJobImage), context: context).map {
            SweepRemoval(label: "VM image \($0.metadata.name) (Xcode \($0.metadata.xcode ?? "?"))", path: $0.directory.path, root: storage.images)
        }
        if !building {
            removals += oldBaseImages(images.filter { !$0.metadata.isJobImage }).map {
                SweepRemoval(label: "base VM image \($0.metadata.name)", path: $0.directory.path, root: storage.images)
            }
        }
        return removals
    }

    static func staleJobImages(_ images: [VMImage], context: SweepContext) -> [VMImage] {
        guard let needed = context.xcodesNeeded, let host = context.hostXcodes, images.count > 1 else { return [] }
        let newest = images.max { isOlder($0, than: $1) }
        let asXcodes = images.map { InstalledXcode(version: $0.metadata.xcode ?? "", build: $0.metadata.xcodeBuild ?? "", path: $0.directory.path) }
        let picked = Set(needed.compactMap { XcodeVersion.best(asXcodes, requested: $0)?.path })
        return images.filter { image in
            guard image.directory.path != newest?.directory.path, !picked.contains(image.directory.path),
                let version = image.metadata.xcode
            else { return false }
            let onHost = host.contains { installed in
                if let build = image.metadata.xcodeBuild, !build.isEmpty, !installed.build.isEmpty { return installed.build == build }
                return installed.version == version
            }
            return !onHost
        }
    }

    static func oldBaseImages(_ bases: [VMImage]) -> [VMImage] {
        guard let newest = bases.max(by: { isOlderBase($0, than: $1) }) else { return [] }
        return bases.filter { $0.directory.path != newest.directory.path }
    }

    private static func isOlder(_ a: VMImage, than b: VMImage) -> Bool {
        let left = XcodeVersion.components(a.metadata.xcode ?? ""), right = XcodeVersion.components(b.metadata.xcode ?? "")
        if left != right { return left.lexicographicallyPrecedes(right) }
        return a.metadata.createdAt < b.metadata.createdAt
    }

    private static func isOlderBase(_ a: VMImage, than b: VMImage) -> Bool {
        let left = XcodeVersion.components(macOSVersion(a)), right = XcodeVersion.components(macOSVersion(b))
        if left != right { return left.lexicographicallyPrecedes(right) }
        return a.metadata.createdAt < b.metadata.createdAt
    }

    /// "26.6.2 (25G83)" → "26.6.2".
    private static func macOSVersion(_ image: VMImage) -> String {
        String(image.metadata.macOS.prefix { $0 != " " })
    }

    // MARK: Plumbing

    static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    static func entries(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    }

    private static func isRunning(_ name: String, _ context: SweepContext) -> Bool {
        UUID(uuidString: name).map(context.runningJobIDs.contains) ?? false
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    static func modified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    /// The latest modification of `path` or anything under it.
    static func lastModified(tree path: String) -> Date? {
        guard var latest = modified(path) else { return nil }
        if let enumerator = FileManager.default.enumerator(atPath: path) {
            while let relative = enumerator.nextObject() as? String {
                if let date = modified(path + "/" + relative), date > latest { latest = date }
            }
        }
        return latest
    }
}
