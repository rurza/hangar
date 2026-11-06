import Foundation
import HangarCore
import Testing

@testable import HangarServer

@Suite struct SchedulerTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    func job(
        _ offset: TimeInterval = 0, xcode: String = "27.2", tools: [String] = [], pinned: UUID? = nil,
        simulator: Platform? = nil, capabilities: Set<String> = [], needsXcodeAccount: Bool = false
    ) -> QueuedJob {
        QueuedJob(
            id: UUID(), buildID: UUID(), createdAt: Self.start.addingTimeInterval(offset), xcode: xcode, tools: tools,
            pinnedMachineID: pinned, simulatorPlatform: simulator, requiredCapabilities: capabilities,
            needsXcodeAccount: needsXcodeAccount)
    }

    func machine(
        _ name: String, isOnline: Bool = true, freeSlots: Int = 1, runningJobs: Int = 0,
        xcodeVersions: [String] = ["27.2.1"], tools: Set<String> = ["git"], freeDiskGB: Double = 100,
        performanceCores: Int = 8, onACPower: Bool = false, canSign: Bool = true, simulatorRuntimes: [String] = [],
        capabilities: Set<String> = [WorkerCapability.testActions], headless: Bool = false, paused: Bool = false,
        vm: Bool = false, vmNotReady: String? = nil
    ) -> MachineSnapshot {
        MachineSnapshot(
            id: UUID(), name: name, isOnline: isOnline, freeSlots: freeSlots, runningJobs: runningJobs,
            xcodeVersions: xcodeVersions, tools: tools, freeDiskGB: freeDiskGB, performanceCores: performanceCores,
            onACPower: onACPower, canSign: canSign, simulatorRuntimes: simulatorRuntimes,
            capabilities: capabilities, headless: headless, paused: paused, vm: vm, vmNotReady: vmNotReady)
    }

    /// A machine whose worker reports VM builds, as `SchedulerLoop.snapshot` sees it.
    func vmMachine(
        _ vm: VMReport, maxConcurrentJobs: Int = 1, runningJobs: Int = 0, freeDiskGB: Double = 400,
        headless: Bool? = nil, hostCanSign: Bool = true
    ) -> MachineSnapshot {
        let report = MachineReport(
            macOSVersion: "26.6", xcodes: [InstalledXcode(version: "26.1", build: "A", path: "/Applications/Xcode.app")],
            chip: "M4", performanceCores: 10, memoryGB: 32, freeDiskGB: freeDiskGB, onACPower: true,
            tools: ["swiftlint": "0.57"], canSignWithoutPrompt: hostCanSign, runningJobIDs: [],
            simulatorRuntimes: ["visionOS 26.1"], capabilities: [WorkerCapability.testActions], headless: headless, vm: vm)
        let machine = Machine(
            id: UUID(), name: "Mini", maxConcurrentJobs: maxConcurrentJobs, lastSeenAt: Self.start, report: report,
            createdAt: Self.start)
        return SchedulerLoop.snapshot(machine, runningJobs: runningJobs, now: Self.start)
    }

    static let image = VMImageInfo(
        name: "xcode-27.2", macOS: "26.6.2 (25G83)", xcode: "27.2", xcodeBuild: "27C5", simulatorRuntimes: ["iOS 27.2"])

    @Test func aVMMacIsJudgedByItsVMsNotItsHost() {
        let vm = VMReport(slots: 2, configuredSlots: 2, freeSlots: 1, storageFreeGB: 150, networkFilter: true, images: [
            Self.image,
            VMImageInfo(name: "xcode-26.4", macOS: "26.6.2", xcode: "26.4", simulatorRuntimes: ["iOS 26.4", "iOS 27.2"]),
            VMImageInfo(name: "vanilla", macOS: "26.6.2"),
        ])
        let snapshot = vmMachine(vm, maxConcurrentJobs: 1, runningJobs: 1, freeDiskGB: 900, headless: false)
        #expect(snapshot.vm)
        #expect(snapshot.vmNotReady == nil)
        // Its slots, not the machine's job limit.
        #expect(snapshot.freeSlots == 1)
        #expect(snapshot.xcodeVersions == ["27.2", "26.4"])
        #expect(snapshot.simulatorRuntimes == ["iOS 26.4", "iOS 27.2"])
        #expect(snapshot.freeDiskGB == 150)
        // The guest has no Xcode account, whatever the host has.
        #expect(snapshot.headless)
        #expect(snapshot.canSign)
        #expect(vmMachine(vm, runningJobs: 3).freeSlots == 0)
    }

    /// A VM Mac signs in its VMs with the server's identity: a host keychain that cannot sign (an owner-run Mac, a
    /// keychain problem) keeps no job off it.
    @Test func aVMMacIsNotJudgedByItsHostKeychain() {
        let vm = VMReport(slots: 2, configuredSlots: 2, freeSlots: 2, storageFreeGB: 150, networkFilter: true, images: [Self.image])
        let snapshot = vmMachine(vm, hostCanSign: false)
        #expect(snapshot.canSign)
        let jobs = [job(), job(1, simulator: .iOS)]
        #expect(Scheduler.plan(jobs: jobs, machines: [snapshot], minFreeDiskGB: 20).assignments.count == 2)
    }

    /// On a host, only a job that signs there waits for a Mac that can sign: an archive or a macOS test. A
    /// simulator test signs ad hoc.
    @Test func onlyJobsThatSignOnTheHostNeedItsKeychain() {
        let workflow = Workflow(
            project: "Demo.xcodeproj", xcode: "27.2",
            actions: [
                WorkflowAction(scheme: "Demo", platform: .iOS, export: .appStoreConnect),
                .test(scheme: "Tests", platform: .iOS), .test(scheme: "MacTests", platform: .macOS),
            ])
        let queued = workflow.actions.map {
            SchedulerLoop.queuedJob(
                id: UUID(), buildID: UUID(), createdAt: Self.start, action: $0, workflow: workflow, pinned: nil,
                teamKey: true)
        }
        #expect(queued.map(\.signsOnHost) == [true, false, true])
        let cannotSign = machine("Mini", freeSlots: 3, canSign: false, simulatorRuntimes: ["iOS 27.2"])
        let plan = Scheduler.plan(jobs: queued, machines: [cannotSign], minFreeDiskGB: 20)
        #expect(plan.assignments == [Assignment(jobID: queued[1].id, machineID: cannotSign.id)])
        #expect(plan.waiting[queued[0].id] == ["Mini": [.cannotSign]])
        #expect(plan.waiting[queued[2].id] == ["Mini": [.cannotSign]])
    }

    @Test func aMacWithoutVMBuildsIsSnapshottedAsBefore() {
        let report = MachineReport(
            macOSVersion: "26.6", xcodes: [InstalledXcode(version: "27.2", build: "A", path: "/Applications/Xcode.app")],
            chip: "M4", performanceCores: 10, memoryGB: 32, freeDiskGB: 300, onACPower: true, tools: ["git": "2"],
            canSignWithoutPrompt: true, runningJobIDs: [], simulatorRuntimes: ["iOS 27.2"])
        let machine = Machine(
            id: UUID(), name: "Mini", maxConcurrentJobs: 2, lastSeenAt: Self.start, report: report, createdAt: Self.start)
        let snapshot = SchedulerLoop.snapshot(machine, runningJobs: 1, now: Self.start)
        #expect(!snapshot.vm)
        #expect(snapshot.vmNotReady == nil)
        #expect(snapshot.freeSlots == 1)
        #expect(snapshot.xcodeVersions == ["27.2"])
        #expect(snapshot.tools == ["git"])
        #expect(snapshot.freeDiskGB == 300)
        #expect(!snapshot.headless)
    }

    @Test func aVMMacWithTwoReadySlotsTakesTwoJobs() {
        let vm = VMReport(slots: 2, configuredSlots: 2, freeSlots: 2, storageFreeGB: 150, networkFilter: true, images: [Self.image])
        let mini = vmMachine(vm, maxConcurrentJobs: 1)
        let (first, second, third) = (job(0), job(1), job(2))
        let plan = Scheduler.plan(jobs: [first, second, third], machines: [mini], minFreeDiskGB: 20)
        #expect(plan.assignments == [
            Assignment(jobID: first.id, machineID: mini.id), Assignment(jobID: second.id, machineID: mini.id),
        ])
        #expect(plan.waiting[third.id] == ["Mini": [.busy]])
    }

    @Test func aVMMacWithNoReadySlotSaysWhyInsteadOfBusy() {
        let filter = "the network filter is not installed: run hangar-worker isolate"
        let vm = VMReport(slots: 0, configuredSlots: 1, freeSlots: 0, storageFreeGB: 150, networkFilter: false,
            problem: filter, images: [Self.image])
        #expect(Scheduler.ineligibility(of: job(), on: vmMachine(vm), minFreeDiskGB: 20) == [.vmNotReady(filter)])
        #expect(Ineligibility.vmNotReady(filter).description == "VM builds not ready: \(filter)")
        var unexplained = vm
        unexplained.problem = nil
        #expect(Scheduler.ineligibility(of: job(), on: vmMachine(unexplained), minFreeDiskGB: 20)
            == [.vmNotReady("no VM slot is ready")])
        // Paused still comes first; and it is a problem to fix, not a wait.
        let paused = machine("Mini", freeSlots: 0, paused: true, vm: true, vmNotReady: filter)
        #expect(Scheduler.ineligibility(of: job(), on: paused, minFreeDiskGB: 20) == [.paused, .vmNotReady(filter)])
        #expect(!HangarServerApp.passingReasons(.vmNotReady(filter)))
    }

    @Test func aVMMacMatchesXcodeAgainstItsImages() {
        let vm = VMReport(slots: 1, configuredSlots: 1, freeSlots: 1, storageFreeGB: 150, networkFilter: true, images: [Self.image])
        let mini = vmMachine(vm)
        #expect(Scheduler.ineligibility(of: job(xcode: "27.2"), on: mini, minFreeDiskGB: 20).isEmpty)
        #expect(Scheduler.ineligibility(of: job(xcode: "27"), on: mini, minFreeDiskGB: 20).isEmpty)
        // The host's Xcode 26.1 does not count.
        #expect(Scheduler.ineligibility(of: job(xcode: "26.1"), on: mini, minFreeDiskGB: 20) == [.noVMImage("26.1")])
        #expect(Ineligibility.noVMImage("26.1").description == "no VM image with Xcode 26.1")
        #expect(!HangarServerApp.passingReasons(.noVMImage("26.1")))
    }

    @Test func aVMMacNeedsNoToolsButItsImagesSimulators() {
        let vm = VMReport(slots: 1, configuredSlots: 1, freeSlots: 1, storageFreeGB: 150, networkFilter: true, images: [Self.image])
        let mini = vmMachine(vm)
        #expect(Scheduler.ineligibility(of: job(tools: ["xcodegen", "swiftlint"]), on: mini, minFreeDiskGB: 20).isEmpty)
        #expect(Scheduler.ineligibility(of: job(tools: ["xcodegen"]), on: machine("Host", tools: []), minFreeDiskGB: 20)
            == [.toolMissing("xcodegen")])
        #expect(Scheduler.ineligibility(of: job(simulator: .iOS), on: mini, minFreeDiskGB: 20).isEmpty)
        // The host has a visionOS runtime; the images do not.
        #expect(Scheduler.ineligibility(of: job(simulator: .visionOS), on: mini, minFreeDiskGB: 20)
            == [.simulatorMissing("visionOS")])
    }

    @Test func aVMMacChecksItsVMStorageAndNeedsATeamKey() {
        let low = VMReport(slots: 1, configuredSlots: 1, freeSlots: 1, storageFreeGB: 12.5, networkFilter: true, images: [Self.image])
        #expect(Scheduler.ineligibility(of: job(), on: vmMachine(low, freeDiskGB: 900), minFreeDiskGB: 20)
            == [.lowDisk(freeGB: 12.5, minimumGB: 20)])
        let roomy = VMReport(slots: 1, configuredSlots: 1, freeSlots: 1, storageFreeGB: 150, networkFilter: true, images: [Self.image])
        #expect(Scheduler.ineligibility(of: job(), on: vmMachine(roomy, freeDiskGB: 5), minFreeDiskGB: 20).isEmpty)
        #expect(Scheduler.ineligibility(of: job(needsXcodeAccount: true), on: vmMachine(roomy, headless: false), minFreeDiskGB: 20)
            == [.needsTeamKey])
    }

    @Test func aPausedMacGetsNoJobAndTheJobWaits() throws {
        let queued = job()
        let paused = machine("Mini", performanceCores: 12, paused: true)
        let plan = Scheduler.plan(jobs: [queued], machines: [paused], minFreeDiskGB: 20)
        #expect(plan.assignments.isEmpty)
        let reasons = try #require(plan.waiting[queued.id])
        #expect(reasons == ["Mini": [.paused]])
        #expect(Scheduler.queueNote(reasons) == "Mini: builds paused")
        // Another Mac takes it, though the paused one ranks higher.
        let laptop = machine("MacBook", performanceCores: 4)
        #expect(Scheduler.plan(jobs: [queued], machines: [paused, laptop], minFreeDiskGB: 20).assignments
            == [Assignment(jobID: queued.id, machineID: laptop.id)])
        // A job pinned to the paused Mac waits for it.
        let pinned = job(pinned: paused.id)
        let pinnedPlan = Scheduler.plan(jobs: [pinned], machines: [paused, laptop], minFreeDiskGB: 20)
        #expect(pinnedPlan.assignments.isEmpty)
        #expect(pinnedPlan.waiting[pinned.id] == ["Mini": [.paused], "MacBook": [.notPinned]])
    }

    @Test func pausedComesFirstAndOtherReasonsStillShow() {
        let busy = machine("Mini", freeSlots: 0, runningJobs: 1, xcodeVersions: ["26.1"], paused: true)
        #expect(Scheduler.ineligibility(of: job(), on: busy, minFreeDiskGB: 20)
            == [.paused, .busy, .xcodeMissing("27.2")])
        #expect(Scheduler.queueNote(["Mini": [.paused, .busy]]) == "Mini: builds paused, busy")
        // Offline says only that, as before.
        #expect(Scheduler.ineligibility(of: job(), on: machine("Mini", isOnline: false, paused: true), minFreeDiskGB: 20)
            == [.offline])
    }

    @Test func pausedDelaysLikeBusyAndLowDisk() {
        #expect(HangarServerApp.passingReasons(.paused))
        #expect(HangarServerApp.passingReasons(.busy))
        #expect(!HangarServerApp.passingReasons(.offline))
    }

    @Test func anArchiveWithAnIndividualKeySkipsAHeadlessMac() throws {
        let queued = job(needsXcodeAccount: true)
        let headless = machine("Mini", performanceCores: 12, headless: true)
        let plan = Scheduler.plan(jobs: [queued], machines: [headless], minFreeDiskGB: 20)
        #expect(plan.assignments.isEmpty)
        let reasons = try #require(plan.waiting[queued.id])
        #expect(reasons == ["Mini": [.needsTeamKey]])
        #expect(Scheduler.queueNote(reasons)
            == "Mini: needs a team App Store Connect key (with an issuer ID): this Mac's worker runs without an Xcode account")
        // A Mac in a login session signs with its Xcode account; a team key signs anywhere.
        let laptop = machine("MacBook", performanceCores: 4)
        #expect(Scheduler.plan(jobs: [queued], machines: [headless, laptop], minFreeDiskGB: 20).assignments
            == [Assignment(jobID: queued.id, machineID: laptop.id)])
        #expect(Scheduler.plan(jobs: [job()], machines: [headless], minFreeDiskGB: 20).assignments.count == 1)
    }

    @Test func onlyArchivesWithoutATeamKeyNeedTheXcodeAccount() {
        let workflow = Workflow(
            project: "Demo.xcodeproj", xcode: "27.2", teamID: "TEAM",
            actions: [WorkflowAction(scheme: "Demo", platform: .iOS, export: .appStoreConnect), .test(scheme: "Tests", platform: .iOS)])
        func needs(_ action: WorkflowAction, teamKey: Bool) -> Bool {
            SchedulerLoop.queuedJob(
                id: UUID(), buildID: UUID(), createdAt: Self.start, action: action, workflow: workflow, pinned: nil,
                teamKey: teamKey
            ).needsXcodeAccount
        }
        #expect(needs(workflow.actions[0], teamKey: false))
        #expect(!needs(workflow.actions[0], teamKey: true))
        #expect(!needs(workflow.actions[1], teamKey: false), "a test signs with the key when there is one, but needs none")
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
