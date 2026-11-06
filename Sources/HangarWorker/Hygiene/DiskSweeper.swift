import Foundation
import HangarCore
import Logging
import Synchronization

/// Keeps the worker's disk clean without anyone asking: on start and every hour it removes what `DiskSweepPlan`
/// finds, each removal confined to the Hangar directory it belongs in (`SafeRemoval`), logs one line saying what went
/// (the first few by name) and how much that freed, and measures what Hangar still uses for the heartbeat.
public final class DiskSweeper: Sendable {
    public struct Locations: Sendable, Equatable {
        public var workDirectory: String
        public var dataDirectory: String
        public var systemTemporary: String
        /// Set with VM builds on.
        public var vm: VMSettings?

        public init(workDirectory: String, dataDirectory: String, systemTemporary: String = NSTemporaryDirectory(), vm: VMSettings? = nil) {
            self.workDirectory = DiskSweepPlan.standardized(workDirectory)
            self.dataDirectory = DiskSweepPlan.standardized(dataDirectory)
            self.systemTemporary = DiskSweepPlan.standardized(systemTemporary)
            self.vm = vm
        }

        var storage: VMStorage? { vm.map { VMStorage(root: $0.storage) } }
        var workspaceDirectories: [String] { Array(Set([workDirectory + "/workspaces", dataDirectory + "/workspaces"])).sorted() }
        var jobTemporaryRoot: String { WorkspaceLayout.temporaryRoot(dataDirectory: workDirectory) }
        var jobsDirectories: [String] { Array(Set([workDirectory + "/jobs", dataDirectory + "/jobs"])).sorted() }
    }

    /// What one sweep did.
    public struct Summary: Sendable, Equatable {
        public var removed: [String] = []
        public var failures: [String] = []
        public var freedBytes: UInt64 = 0
        public var usage: HangarDiskUsage?

        /// How many removals the line names; the rest are counted.
        static let namedInLine = 5

        /// The one line logged; nil when the sweep found nothing to remove.
        public var line: String? {
            guard !removed.isEmpty || !failures.isEmpty else { return nil }
            var line = "disk sweep"
            if !removed.isEmpty {
                var named = removed.prefix(Self.namedInLine).joined(separator: ", ")
                if removed.count > Self.namedInLine { named += " and \(removed.count - Self.namedInLine) more" }
                line += " removed \(named) and freed \(DiskUsage.text(freedBytes))"
            }
            if !failures.isEmpty { line += (removed.isEmpty ? " " : "; ") + "could not remove \(failures.joined(separator: "; "))" }
            if let usage { line += "; Hangar uses \(DiskUsage.text(UInt64(usage.totalGB * 1_000_000_000))) on this Mac" }
            return line
        }
    }

    public static let interval: Duration = .seconds(3600)

    let locations: Locations
    private let workspaces: WorkspaceUse
    private let pool: VMSlotPool?
    private let hostXcodes: @Sendable () async -> [InstalledXcode]?
    private let now: @Sendable () -> Date
    private let latest = Mutex<HangarDiskUsage?>(nil)
    private let logger = Logger(label: "app.hangar.worker.disk")

    /// `pool` is the VM slot pool: an image or slot is removed only while every slot is held by the sweep, so no job
    /// and no state being saved uses it. `hostXcodes` lists this Mac's Xcodes (nil when it cannot tell).
    public init(
        locations: Locations, workspaces: WorkspaceUse = .shared, pool: VMSlotPool? = nil,
        hostXcodes: @escaping @Sendable () async -> [InstalledXcode]? = { nil },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.locations = locations
        self.workspaces = workspaces
        self.pool = pool
        self.hostXcodes = hostXcodes
        self.now = now
    }

    /// The last measurement, for the heartbeat; nil until the first sweep.
    public var usage: HangarDiskUsage? { latest.withLock { $0 } }

    /// Sweeps once and logs the line. `xcodesNeeded` comes from the last heartbeat (nil before one).
    @discardableResult
    public func sweep(runningJobIDs: Set<UUID>, xcodesNeeded: [String]?) async -> Summary {
        let summary = await sweepQuietly(runningJobIDs: runningJobIDs, xcodesNeeded: xcodesNeeded)
        if let line = summary.line { logger.notice("\(line)") }
        return summary
    }

    func sweepQuietly(runningJobIDs: Set<UUID>, xcodesNeeded: [String]?) async -> Summary {
        var context = SweepContext(now: now(), runningJobIDs: runningJobIDs, xcodesNeeded: xcodesNeeded)
        if xcodesNeeded != nil, locations.vm != nil { context.hostXcodes = await hostXcodes() }
        var removals = DiskSweepPlan.temporary(
            systemTemporary: locations.systemTemporary, jobTemporaryRoot: locations.jobTemporaryRoot, context: context)
        removals += DiskSweepPlan.jobDirectories(in: locations.jobsDirectories, context: context)
        removals += DiskSweepPlan.workspaces(
            in: locations.workspaceDirectories, vmBuilds: locations.vm != nil, context: context)
        // Images and slots go only while the sweep holds every slot: no job runs and no state is being saved.
        var held: (pool: VMSlotPool, slots: [Int])?
        defer { held.map { held in held.slots.forEach(held.pool.release) } }
        if let storage = locations.storage, let settings = locations.vm {
            var vm = DiskSweepPlan.vmStorage(storage, settings: settings, context: context)
            let partials = storage.images + "/" + VMStorage.partialPrefix
            let inUseByJobs: (SweepRemoval) -> Bool = { removal in
                (removal.root == storage.images && !removal.path.hasPrefix(partials)) || removal.root.hasSuffix("/slots")
            }
            if vm.contains(where: inUseByJobs) {
                let pool = pool ?? VMSlotPool(count: settings.slots)
                let slots = (0..<settings.slots).filter { pool.acquire($0) }
                held = (pool, slots)
                if slots.count < settings.slots || !runningJobIDs.isEmpty { vm.removeAll(where: inUseByJobs) }
            }
            removals += vm
        }
        var summary = Summary()
        if !removals.isEmpty {
            let before = measure()
            for removal in removals {
                do {
                    let removed: Bool
                    if removal.workspace {
                        removed = try workspaces.whileIdle(removal.path) {
                            try SafeRemoval.removeItem(atPath: removal.path, within: removal.root)
                        }
                    } else {
                        if removal.jobDirectory { try SecretsMaterializer(directory: removal.path + "/secrets").wipe() }
                        try SafeRemoval.removeItem(atPath: removal.path, within: removal.root)
                        removed = true
                    }
                    if removed { summary.removed.append(removal.label) }
                } catch {
                    summary.failures.append("\(removal.label): \(error)")
                }
            }
            let after = measure()
            summary.freedBytes = before.total > after.total ? before.total - after.total : 0
            summary.usage = after.report(at: context.now)
        } else {
            summary.usage = measure().report(at: context.now)
        }
        latest.withLock { $0 = summary.usage }
        return summary
    }

    // MARK: Measuring

    struct Measurement {
        /// Each piece of Hangar's usage, clones counted in the first piece that holds them.
        var parts: [(label: String, bytes: UInt64)]

        var total: UInt64 { parts.reduce(0) { $0 + $1.bytes } }

        func report(at date: Date) -> HangarDiskUsage {
            let parts = parts.filter { $0.bytes >= 1_000_000 }
                .sorted { $0.bytes > $1.bytes }
                .map { HangarDiskUsage.Part(label: $0.label, gb: DiskUsage.gigabytes($0.bytes)) }
            return HangarDiskUsage(totalGB: DiskUsage.gigabytes(total), parts: parts, measuredAt: date)
        }
    }

    /// Everything of Hangar's this worker knows about: VM storage, the work and data directories and its
    /// `hangar-*` temporary directories. Images come first, so a slot's saved state and a running VM's disk, both
    /// clones, count only the blocks they changed.
    func measure() -> Measurement {
        let temporary = DiskSweepPlan.entries(locations.systemTemporary).filter { $0.hasPrefix("hangar-") }
            .map { locations.systemTemporary + "/" + $0 }
        var images: [String] = [], slots: [String] = []
        if let storage = locations.storage {
            for name in DiskSweepPlan.entries(storage.images) {
                let image = storage.images + "/" + name
                for entry in DiskSweepPlan.entries(image) {
                    if entry == "slots" { slots.append(image + "/" + entry) } else { images.append(image + "/" + entry) }
                }
            }
        }
        let rest = [locations.storage?.root, locations.workDirectory, locations.dataDirectory].compactMap { $0 } + temporary
        let groups: [(String, [String])] = [
            ("VM images", images),
            ("Saved VM states", slots),
            ("Running VMs", locations.storage.map { [$0.jobs] } ?? []),
            ("Workspaces", locations.workspaceDirectories),
            ("Other", rest),
        ]
        let bytes = DiskUsage.bytes(ofGroups: groups.map(\.1))
        return Measurement(parts: zip(groups.map(\.0), bytes).map { ($0, $1) })
    }
}
