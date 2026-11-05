import Foundation
import HangarCore
import Testing

@testable import HangarServer

@Suite struct SchedulerTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    func job(
        _ offset: TimeInterval = 0, xcode: String = "27.2", tools: [String] = [], pinned: UUID? = nil,
        simulator: Platform? = nil, capabilities: Set<String> = []
    ) -> QueuedJob {
        QueuedJob(
            id: UUID(), buildID: UUID(), createdAt: Self.start.addingTimeInterval(offset), xcode: xcode, tools: tools,
            pinnedMachineID: pinned, simulatorPlatform: simulator, requiredCapabilities: capabilities)
    }

    func machine(
        _ name: String, isOnline: Bool = true, freeSlots: Int = 1, runningJobs: Int = 0,
        xcodeVersions: [String] = ["27.2.1"], tools: Set<String> = ["git"], freeDiskGB: Double = 100,
        performanceCores: Int = 8, onACPower: Bool = false, canSign: Bool = true, simulatorRuntimes: [String] = [],
        capabilities: Set<String> = [WorkerCapability.testActions]
    ) -> MachineSnapshot {
        MachineSnapshot(
            id: UUID(), name: name, isOnline: isOnline, freeSlots: freeSlots, runningJobs: runningJobs,
            xcodeVersions: xcodeVersions, tools: tools, freeDiskGB: freeDiskGB, performanceCores: performanceCores,
            onACPower: onACPower, canSign: canSign, simulatorRuntimes: simulatorRuntimes,
            capabilities: capabilities)
    }

    @Test func aJobNeedingACapabilityWaitsForAnUpdatedWorker() throws {
        let queued = job(capabilities: [WorkerCapability.testActions])
        let old = machine("Old", capabilities: [])
        let plan = Scheduler.plan(jobs: [queued], machines: [old], minFreeDiskGB: 20)
        #expect(plan.assignments.isEmpty)
        let reasons = try #require(plan.waiting[queued.id])
        #expect(reasons == ["Old": [.workerOutdated]])
        #expect(Scheduler.queueNote(reasons) == "Old: update the worker (run the install command again)")
        let updated = machine("New")
        #expect(Scheduler.plan(jobs: [queued], machines: [old, updated], minFreeDiskGB: 20).assignments
            == [Assignment(jobID: queued.id, machineID: updated.id)])
        // Jobs that need nothing still go to old workers.
        #expect(Scheduler.plan(jobs: [job()], machines: [old], minFreeDiskGB: 20).assignments.count == 1)
    }

    @Test func aSimulatorTestNeedsARuntimeOfItsPlatform() throws {
        let queued = job(simulator: .iOS)
        let vision = machine("Vision", simulatorRuntimes: ["visionOS 27.1"])
        let phone = machine("Phone", performanceCores: 1, simulatorRuntimes: ["iOS 27.2", "visionOS 27.1"])
        let plan = Scheduler.plan(jobs: [queued], machines: [vision, phone], minFreeDiskGB: 20)
        #expect(plan.assignments == [Assignment(jobID: queued.id, machineID: phone.id)])

        let waiting = Scheduler.plan(jobs: [queued], machines: [vision], minFreeDiskGB: 20)
        #expect(waiting.waiting[queued.id] == ["Vision": [.simulatorMissing("iOS")]])
        #expect(Scheduler.queueNote(try #require(waiting.waiting[queued.id])) == "Vision: no iOS simulator")
        // Archives and macOS tests need none.
        #expect(Scheduler.plan(jobs: [job()], machines: [vision], minFreeDiskGB: 20).assignments.count == 1)
    }

    @Test func prefersIdleThenCoresThenDiskThenAC() {
        // Every machine has one slot and one running job except where noted; each differs from `base` in one field.
        let base = machine("base", runningJobs: 1)
        let ac = machine("ac", runningJobs: 1, onACPower: true)
        let disk = machine("disk", runningJobs: 1, freeDiskGB: 200)
        let cores = machine("cores", runningJobs: 1, performanceCores: 10)
        let idle = machine("idle", runningJobs: 0)
        let jobs = (0..<5).map { job(TimeInterval($0)) }
        let plan = Scheduler.plan(jobs: jobs.reversed(), machines: [base, ac, disk, cores, idle], minFreeDiskGB: 20)
        #expect(plan.assignments == zip(jobs, [idle, cores, disk, ac, base]).map {
            Assignment(jobID: $0.id, machineID: $1.id)
        })
        #expect(plan.waiting.isEmpty)
    }

    @Test func xcodeMissingIsReported() throws {
        let queued = job(xcode: "27.1")
        let plan = Scheduler.plan(jobs: [queued], machines: [machine("MacBook Pro")], minFreeDiskGB: 20)
        #expect(plan.assignments.isEmpty)
        let reasons = try #require(plan.waiting[queued.id])
        #expect(reasons == ["MacBook Pro": [.xcodeMissing("27.1")]])
        #expect(Scheduler.queueNote(reasons).contains("MacBook Pro: Xcode 27.1 not installed"))
    }

    @Test func pinnedJobWaitsForItsMachine() {
        let pinnedMachine = machine("Mac mini", freeSlots: 0, runningJobs: 1)
        let other = machine("MacBook Pro")
        let queued = job(pinned: pinnedMachine.id)
        let plan = Scheduler.plan(jobs: [queued], machines: [other, pinnedMachine], minFreeDiskGB: 20)
        #expect(plan.assignments.isEmpty)
        #expect(plan.waiting[queued.id] == ["Mac mini": [.busy], "MacBook Pro": [.notPinned]])
        #expect(
            Scheduler.queueNote(plan.waiting[queued.id]!)
                == "Mac mini: busy; MacBook Pro: job is pinned to another machine")

        let free = machine("Mac mini")
        let pinnedToFree = job(pinned: free.id)
        let assigned = Scheduler.plan(jobs: [pinnedToFree], machines: [other, free], minFreeDiskGB: 20)
        #expect(assigned.assignments == [Assignment(jobID: pinnedToFree.id, machineID: free.id)])
    }

    @Test func oneSlotPerMachineByDefault() {
        let only = machine("MacBook Pro")
        let first = job(0)
        let second = job(1)
        let plan = Scheduler.plan(jobs: [second, first], machines: [only], minFreeDiskGB: 20)
        #expect(plan.assignments == [Assignment(jobID: first.id, machineID: only.id)])
        #expect(plan.waiting == [second.id: ["MacBook Pro": [.busy]]])
    }

    @Test func secondJobGoesToSecondMachine() {
        let strong = machine("Mac Studio", performanceCores: 16)
        let weak = machine("Mac mini", performanceCores: 4)
        let first = job(0)
        let second = job(1)
        let plan = Scheduler.plan(jobs: [first, second], machines: [weak, strong], minFreeDiskGB: 20)
        #expect(plan.assignments == [
            Assignment(jobID: first.id, machineID: strong.id), Assignment(jobID: second.id, machineID: weak.id),
        ])
        #expect(plan.waiting.isEmpty)
    }

    @Test func lowDiskAndMissingToolAccumulate() throws {
        let poor = machine("MacBook Pro", freeDiskGB: 12, canSign: false)
        let offline = machine("Mac mini", isOnline: false)
        let queued = job(tools: ["xcodegen", "git", "swiftlint"])
        let plan = Scheduler.plan(jobs: [queued], machines: [poor, offline], minFreeDiskGB: 20)
        #expect(plan.assignments.isEmpty)
        let reasons = try #require(plan.waiting[queued.id])
        #expect(reasons == [
            "MacBook Pro": [
                .lowDisk(freeGB: 12, minimumGB: 20), .toolMissing("xcodegen"), .toolMissing("swiftlint"), .cannotSign,
            ],
            "Mac mini": [.offline],
        ])
        #expect(
            Scheduler.queueNote(reasons) == "Mac mini: offline; MacBook Pro: only 12 GB free (needs 20 GB), "
                + "xcodegen not installed, swiftlint not installed, cannot sign without a prompt")
        #expect(Ineligibility.lowDisk(freeGB: 12.5, minimumGB: 20).description == "only 12.5 GB free (needs 20 GB)")
    }

    @Test func noMachinesNote() {
        let queued = job()
        let plan = Scheduler.plan(jobs: [queued], machines: [], minFreeDiskGB: 20)
        #expect(plan.waiting == [queued.id: [:]])
        #expect(Scheduler.queueNote([:]) == "no machines registered")
    }
}
