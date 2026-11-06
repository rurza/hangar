import Foundation
import HangarCore
import Testing

@testable import HangarWorker

/// A scratch directory standing in for a Mac's Hangar folders, with a fixed clock: everything is dated against `now`.
private struct Disk {
    let root: String
    static let now = Date(timeIntervalSince1970: 1_793_000_000)  // early November 2026

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sweep-\(UUID().uuidString)")
            .standardizedFileURL.path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func file(_ relative: String, bytes: Int = 16, daysOld: Double = 0) throws -> String {
        let path = path(relative)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: path))
        // The folders it was written into are as old as it is.
        var folder = (relative as NSString).deletingLastPathComponent
        while !folder.isEmpty {
            try FileManager.default.setAttributes(
                [.modificationDate: Self.now.addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: self.path(folder))
            folder = (folder as NSString).deletingLastPathComponent
        }
        try age(relative, days: daysOld)
        return path
    }

    func directory(_ relative: String, daysOld: Double = 0) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
        try age(relative, days: daysOld)
    }

    /// Dates `relative` and everything under it `days` before `now`.
    func age(_ relative: String, days: Double) throws {
        let date = Self.now.addingTimeInterval(-days * 86_400)
        let top = path(relative)
        var paths = [top]
        if let enumerator = FileManager.default.enumerator(atPath: top) {
            while let child = enumerator.nextObject() as? String { paths.append(top + "/" + child) }
        }
        for path in paths.reversed() { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path) }
    }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: path(relative)) }

    /// An image in `vm/images/<name>`: a job image when `xcode` is set, else a base.
    func image(
        _ name: String, xcode: String? = nil, build: String? = nil, macOS: String = "26.6.2 (25G83)", createdDaysAgo: Double = 10,
        slots: [String] = []
    ) throws {
        let directory = VMStorage(root: path("vm")).image(name)
        try FileManager.default.createDirectory(atPath: directory.path, withIntermediateDirectories: true)
        try VMBundleFile.write(
            TartConfig(
                cpuCountMin: 2, cpuCount: 4, memorySizeMin: 4 << 30, memorySize: 8 << 30, macAddress: "72:76:f4:5e:d8:14",
                hardwareModel: "aHc=", ecid: "ZWNpZA=="),
            to: directory.config)
        try VMBundleFile.write(
            VMImageMetadata(
                name: name, macOS: macOS, xcode: xcode, xcodeBuild: build, source: "test",
                createdAt: Self.now.addingTimeInterval(-createdDaysAgo * 86_400), buildUser: xcode == nil ? nil : "builder"),
            to: directory.metadata)
        try file("vm/images/\(name)/disk.img", bytes: 1_200_000)
        for slot in slots { try file("vm/images/\(name)/slots/\(slot)/state.vzstate", bytes: 4096) }
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: root) }
}

@Suite struct TemporarySweepTests {
    @Test func hangarTemporaryDirectoriesGoOnceADayOld() throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        try disk.file("T/hangar-doctor-1/probe", daysOld: 2)
        try disk.file("T/hangar-isolate-2/x", daysOld: 3)
        try disk.directory("T/hangar-isolate-empty", daysOld: 5)
        // In use: something inside changed an hour ago.
        try disk.file("T/hangar-pf-3/old", daysOld: 4)
        try disk.file("T/hangar-pf-3/new", daysOld: 0.04)
        try disk.file("T/other-app/file", daysOld: 30)
        let running = UUID()
        try disk.directory("work/tmp/\(running.uuidString)")
        try disk.directory("work/tmp/\(UUID().uuidString)")
        let removals = DiskSweepPlan.temporary(
            systemTemporary: disk.path("T") + "/", jobTemporaryRoot: disk.path("work/tmp"),
            context: SweepContext(now: Disk.now, runningJobIDs: [running]))
        let names = removals.map { ($0.path as NSString).lastPathComponent }
        #expect(Set(names.prefix(3)) == ["hangar-doctor-1", "hangar-isolate-2", "hangar-isolate-empty"])
        #expect(names.count == 4)
        #expect(!names.contains(running.uuidString))
        #expect(removals.allSatisfy { SafeRemoval.isStrictlyInside($0.path, root: $0.root) })
    }
}

@Suite struct WorkspaceSweepTests {
    @Test func aVMMacRemovesEveryHostWorkspace() throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        try disk.file("work/workspaces/batfi/repository/file")
        try disk.file("work/workspaces/legilo/repository/file")
        let removals = DiskSweepPlan.workspaces(
            in: [disk.path("work/workspaces"), disk.path("data/workspaces")], vmBuilds: true,
            context: SweepContext(now: Disk.now))
        #expect(removals == [SweepRemoval(
            label: "host workspaces batfi, legilo", path: disk.path("work/workspaces"), root: disk.path("work"))])
    }

    @Test func aHostMacRemovesWorkspacesNotBuiltForTwoWeeks() throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        try disk.file("work/workspaces/fresh/\(WorkspaceUse.markerName)", daysOld: 2)
        try disk.file("work/workspaces/idle/\(WorkspaceUse.markerName)", daysOld: 15)
        // From before the marker: judged by its checkout's git state.
        try disk.file("work/workspaces/legacy-idle/repository/.git/FETCH_HEAD", daysOld: 20)
        try disk.age("work/workspaces/legacy-idle", days: 20)
        try disk.file("work/workspaces/legacy-busy/repository/.git/FETCH_HEAD", daysOld: 1)
        try disk.age("work/workspaces/legacy-busy", days: 20)
        try disk.file("work/workspaces/legacy-busy/repository/.git/FETCH_HEAD", daysOld: 1)
        let removals = DiskSweepPlan.workspaces(
            in: [disk.path("work/workspaces")], vmBuilds: false, context: SweepContext(now: Disk.now))
        #expect(removals.map(\.label) == ["workspace idle", "workspace legacy-idle"])
        #expect(removals.allSatisfy { $0.workspace && $0.root == disk.path("work/workspaces") })
    }

    @Test func aJobMarksItsWorkspaceAndHoldsItAgainstTheSweep() throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        let use = WorkspaceUse()
        let workspace = disk.path("work/workspaces/legilo")
        let lease = use.begin(workspace)
        #expect(FileManager.default.fileExists(atPath: workspace + "/" + WorkspaceUse.markerName))
        var removed = false
        #expect(use.whileIdle(workspace) { removed = true } == false)
        #expect(!removed)
        lease.end()
        lease.end()
        #expect(use.whileIdle(workspace) { removed = true })
        #expect(removed && use.inUse.isEmpty)
    }
}

@Suite struct VMStorageSweepTests {
    private let settings = VMSettings(storage: "/unused", slots: 2)

    private func plan(_ disk: Disk, _ context: SweepContext) -> [String] {
        DiskSweepPlan.vmStorage(VMStorage(root: disk.path("vm")), settings: settings, context: context).map(\.label)
    }

    @Test func leftoverClonesPartialsAndExtraSlotsGo() throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        let running = UUID(), leftover = UUID()
        try disk.file("vm/jobs/\(running.uuidString)/disk.img")
        try disk.file("vm/jobs/\(leftover.uuidString)/disk.img")
        try disk.image("vanilla-26.6.2", slots: ["0"])
        try disk.image("xcode-27.2", xcode: "27.2", build: "27B52", slots: ["0", "1", "2", "junk"])
        // An import that died, one from an older worker left a week ago, and one still being built.
        try disk.file("vm/images/.partial-dead/\(VMPartialLock.fileName)")
        try disk.file("vm/images/.partial-old/disk.img", daysOld: 7)
        try disk.directory("vm/images/.partial-live")
        let lock = try VMPartialLock(disk.path("vm/images/.partial-live"))
        defer { lock.release() }
        let labels = plan(disk, SweepContext(now: Disk.now, runningJobIDs: [running]))
        #expect(labels == [
            "VM clone \(leftover.uuidString)", "unfinished VM image dead", "unfinished VM image old",
            "slot 0 of vanilla-26.6.2", "slot 2 of xcode-27.2", "slot junk of xcode-27.2",
        ])
    }

    @Test func anOldJobImageGoesOnceItsXcodeIsGoneAndNoJobNeedsIt() throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        try disk.image("xcode-27.1", xcode: "27.1", build: "27A10", slots: ["0"])
        try disk.image("xcode-27.2", xcode: "27.2", build: "27B52")
        try disk.image("xcode-27.3", xcode: "27.3", build: "27C1")
        let host = [InstalledXcode(version: "27.3", build: "27C1", path: "/Applications/Xcode.app")]
        // Unknown needs or unknown Xcodes: nothing goes.
        #expect(plan(disk, SweepContext(now: Disk.now, hostXcodes: host)).isEmpty)
        #expect(plan(disk, SweepContext(now: Disk.now, xcodesNeeded: [])).isEmpty)
        #expect(plan(disk, SweepContext(now: Disk.now, xcodesNeeded: ["26"], hostXcodes: host))
            == ["VM image xcode-27.1 (Xcode 27.1)", "VM image xcode-27.2 (Xcode 27.2)"])
        // A queued job asks for 27.2: its image stays. "27" picks the newest, which stays anyway.
        #expect(plan(disk, SweepContext(now: Disk.now, xcodesNeeded: ["27.2", "27"], hostXcodes: host))
            == ["VM image xcode-27.1 (Xcode 27.1)"])
        // Still on this Mac (same build): it stays.
        let both = host + [InstalledXcode(version: "27.1", build: "27A10", path: "/Applications/Xcode-27.1.app")]
        #expect(plan(disk, SweepContext(now: Disk.now, xcodesNeeded: [], hostXcodes: both)) == ["VM image xcode-27.2 (Xcode 27.2)"])
    }

    @Test func theNewestJobImageStaysEvenWithoutItsXcode() throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        try disk.image("xcode-27.2", xcode: "27.2")
        #expect(plan(disk, SweepContext(now: Disk.now, xcodesNeeded: [], hostXcodes: [])).isEmpty)
    }

    @Test func onlyTheNewestBaseStaysAndNoneGoesWhileAnImageIsBuilt() throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        try disk.image("vanilla-26.6.2", macOS: "26.6.2")
        try disk.image("vanilla-26.10", macOS: "26.10", createdDaysAgo: 1)
        try disk.image("vanilla-26.6.2-again", macOS: "26.6.2", createdDaysAgo: 2)
        #expect(plan(disk, SweepContext(now: Disk.now)) == ["base VM image vanilla-26.6.2", "base VM image vanilla-26.6.2-again"])
        try disk.directory("vm/images/.partial-xcode-27.3")
        let lock = try VMPartialLock(disk.path("vm/images/.partial-xcode-27.3"))
        defer { lock.release() }
        #expect(plan(disk, SweepContext(now: Disk.now)).isEmpty)
    }

    @Test func aPartialLockedElsewhereCannotBeLockedAgain() throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        try disk.directory("vm/images/.partial-x")
        let lock = try VMPartialLock(disk.path("vm/images/.partial-x"))
        #expect(!VMPartialLock.isAbandoned(disk.path("vm/images/.partial-x"), now: Disk.now))
        lock.release()
        #expect(VMPartialLock.isAbandoned(disk.path("vm/images/.partial-x"), now: Disk.now))
    }
}

@Suite struct DiskSweeperTests {
    private func sweeper(_ disk: Disk, vm: VMSettings? = nil, pool: VMSlotPool? = nil, use: WorkspaceUse = WorkspaceUse()) -> DiskSweeper {
        DiskSweeper(
            locations: DiskSweeper.Locations(
                workDirectory: disk.path("work"), dataDirectory: disk.path("data"), systemTemporary: disk.path("T"), vm: vm),
            workspaces: use, pool: pool,
            hostXcodes: { [InstalledXcode(version: "27.3", build: "27C1", path: "/Applications/Xcode.app")] },
            now: { Disk.now })
    }

    @Test func aSweepRemovesWhatThePlanFoundAndSaysWhatItFreed() async throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        try disk.file("T/hangar-doctor-1/probe", bytes: 3_000_000, daysOld: 2)
        try disk.file("work/workspaces/idle/\(WorkspaceUse.markerName)", daysOld: 30)
        try disk.file("work/workspaces/idle/repository/big", bytes: 2_000_000, daysOld: 30)
        try disk.file("work/workspaces/busy/\(WorkspaceUse.markerName)", daysOld: 30)
        try disk.file("work/workspaces/fresh/repository/file", bytes: 1_000_000)
        let use = WorkspaceUse()
        let lease = use.begin(disk.path("work/workspaces/busy"))
        defer { lease.end() }
        try disk.age("work/workspaces/busy", days: 30)
        let summary = await sweeper(disk, use: use).sweepQuietly(runningJobIDs: [], xcodesNeeded: nil)
        #expect(summary.removed == ["temporary hangar-doctor-1", "workspace idle"])
        #expect(summary.failures.isEmpty)
        #expect(summary.freedBytes >= 5_000_000 && summary.freedBytes < 5_200_000)
        #expect(!disk.exists("T/hangar-doctor-1") && !disk.exists("work/workspaces/idle"))
        #expect(disk.exists("work/workspaces/busy") && disk.exists("work/workspaces/fresh"))
        let usage = try #require(summary.usage)
        #expect(usage.totalGB > 0.0009 && usage.totalGB < 0.0011)
        #expect(usage.parts.map(\.label) == ["Workspaces"])
        #expect(summary.line == "disk sweep removed temporary hangar-doctor-1, workspace idle and freed 5 MB; Hangar uses 1 MB on this Mac")
    }

    @Test func aSweepWithNothingToRemoveStillMeasuresAndLogsNothing() async throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        try disk.file("work/workspaces/fresh/repository/file", bytes: 2_000_000)
        let sweeper = sweeper(disk)
        #expect(sweeper.usage == nil)
        let summary = await sweeper.sweepQuietly(runningJobIDs: [], xcodesNeeded: nil)
        #expect(summary.removed.isEmpty && summary.line == nil)
        #expect(sweeper.usage == summary.usage && summary.usage != nil)
    }

    @Test func imagesGoOnlyWhileTheSweepHoldsEverySlot() async throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        try disk.image("xcode-27.1", xcode: "27.1", slots: ["0"])
        try disk.image("xcode-27.3", xcode: "27.3", build: "27C1", slots: ["0", "1", "5"])
        let leftover = UUID()
        try disk.file("vm/jobs/\(leftover.uuidString)/disk.img")
        let settings = VMSettings(storage: disk.path("vm"), slots: 2)
        let pool = VMSlotPool(count: 2)
        // A job holds slot 1: the image and the extra slot wait, the leftover clone goes.
        #expect(pool.acquire(1))
        var summary = await sweeper(disk, vm: settings, pool: pool).sweepQuietly(runningJobIDs: [], xcodesNeeded: [])
        #expect(summary.removed == ["VM clone \(leftover.uuidString)"])
        #expect(disk.exists("vm/images/xcode-27.1") && disk.exists("vm/images/xcode-27.3/slots/5"))
        #expect(pool.freeCount == 1)
        // A job is running (its slot already released, its clone in place): images wait too.
        pool.release(1)
        summary = await sweeper(disk, vm: settings, pool: pool).sweepQuietly(runningJobIDs: [UUID()], xcodesNeeded: [])
        #expect(summary.removed.isEmpty)
        summary = await sweeper(disk, vm: settings, pool: pool).sweepQuietly(runningJobIDs: [], xcodesNeeded: [])
        #expect(summary.removed == ["slot 5 of xcode-27.3", "VM image xcode-27.1 (Xcode 27.1)"])
        #expect(!disk.exists("vm/images/xcode-27.1") && disk.exists("vm/images/xcode-27.3/slots/1"))
        #expect(pool.freeCount == 2)
        #expect(summary.usage?.parts.first?.label == "VM images")
    }

    @Test func usageNamesImagesSavedStatesAndRunningVMsApart() async throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        try disk.image("xcode-27.3", xcode: "27.3", build: "27C1", slots: ["0"])
        try disk.file("vm/images/xcode-27.3/disk.img", bytes: 5_000_000)
        try disk.file("vm/images/xcode-27.3/slots/0/state.vzstate", bytes: 3_000_000)
        let running = UUID()
        try disk.file("vm/jobs/\(running.uuidString)/disk.img", bytes: 2_000_000)
        let usage = try #require(
            await sweeper(disk, vm: VMSettings(storage: disk.path("vm")), pool: VMSlotPool(count: 1))
                .sweepQuietly(runningJobIDs: [running], xcodesNeeded: nil).usage)
        #expect(usage.parts.map(\.label) == ["VM images", "Saved VM states", "Running VMs"])
        #expect(usage.parts.map { ($0.gb * 1000).rounded() } == [5, 3, 2])
    }

    @Test func aVMMacsHostWorkspacesGoWithTheirFolder() async throws {
        let disk = try Disk()
        defer { disk.cleanUp() }
        try disk.file("work/workspaces/legilo/repository/file", bytes: 1_000_000)
        let summary = await sweeper(disk, vm: VMSettings(storage: disk.path("vm"))).sweepQuietly(runningJobIDs: [], xcodesNeeded: nil)
        #expect(summary.removed == ["host workspaces legilo"])
        #expect(!disk.exists("work/workspaces") && disk.exists("work"))
    }
}

@Suite struct DiskUsageReportCodingTests {
    @Test func theReportCarriesHangarsDiskUsageAndAnOlderOneHasNone() throws {
        let usage = HangarDiskUsage(
            totalGB: 50.7, parts: [.init(label: "VM images", gb: 49.4), .init(label: "Workspaces", gb: 1.3)],
            measuredAt: Date(timeIntervalSince1970: 1_793_000_000))
        let report = MachineReport(
            macOSVersion: "26.6", xcodes: [], chip: "M4", performanceCores: 4, memoryGB: 16, freeDiskGB: 100,
            onACPower: true, tools: [:], canSignWithoutPrompt: false, runningJobIDs: [], diskUsage: usage)
        let decoded = try JSONCoding.decoder.decode(MachineReport.self, from: try JSONCoding.encoder.encode(report))
        #expect(decoded.diskUsage == usage)
        var older = try JSONSerialization.jsonObject(with: try JSONCoding.encoder.encode(report)) as! [String: Any]
        older["diskUsage"] = nil
        let fromOlder = try JSONCoding.decoder.decode(MachineReport.self, from: try JSONSerialization.data(withJSONObject: older))
        #expect(fromOlder.diskUsage == nil)
    }

    @Test func anOlderServerSaysNothingAboutWhatJobsNeed() throws {
        let response = try JSONCoding.decoder.decode(HeartbeatResponse.self, from: Data(#"{"cancelJobIDs":[]}"#.utf8))
        #expect(response.xcodesNeeded == nil)
    }
}
