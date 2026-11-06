import Clocks
import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarServer

/// The scheduler's wall clock, moved by hand.
final class FakeNow: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var date: Date { value.withLock { $0 } }
    func advance(seconds: Int) { value.withLock { $0 = $0.addingTimeInterval(TimeInterval(seconds)) } }
}

private struct FixedSource: KnownNumberSource {
    var name = "app-store-connect"
    func highestNumber(for app: App) async throws -> Int? { 300 }
}

@Suite(.timeLimit(.minutes(1))) struct SchedulerLoopTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    let builds: BuildRepository
    let machines: MachineRepository
    let numbers: BuildNumberService
    let events = EventBus()
    let clock = TestClock()
    let current = FakeNow(Self.start)
    let app: App
    let macBook: Machine
    let loop: SchedulerLoop

    init() throws {
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        builds = BuildRepository(database: database)
        machines = MachineRepository(database: database)
        numbers = BuildNumberService(repository: builds, sources: { [FixedSource()] })
        app = try AppRepository(database: database).create(
            CreateAppRequest(name: "Demo", repoURL: "https://example.com/r.git", appStoreConnectAppID: "1"))
        macBook = try machines.create(name: "MacBook Pro").0
        let current = current
        loop = SchedulerLoop(
            builds: builds, machines: machines, events: events, config: SchedulerConfig(), clock: clock,
            now: { current.date })
        try report(macBook)
    }

    var now: Date { current.date }

    /// Moves the scheduler's wall clock and its sleep clock together.
    func advance(seconds: Int) async {
        current.advance(seconds: seconds)
        await clock.advance(by: .seconds(seconds))
    }

    func report(_ machine: Machine, freeDiskGB: Double = 100, headless: Bool? = nil, vm: VMReport? = nil) throws {
        // A VM Mac in these tests is one the owner allowed VM builds on.
        if vm != nil { _ = try machines.setVMBuilds(id: machine.id, true) }
        try machines.updateReport(
            id: machine.id,
            report: MachineReport(
                macOSVersion: "26.0", xcodes: [InstalledXcode(version: "27.2", build: "A1", path: "/Applications/Xcode.app")],
                chip: "M4", performanceCores: 4, memoryGB: 16, freeDiskGB: freeDiskGB, onACPower: true, tools: ["git": "2.45"],
                canSignWithoutPrompt: true, runningJobIDs: [], headless: headless, vm: vm),
            seenAt: now)
    }

    /// Inserts a one-job build with a freshly reserved number; returns the build and its job ID.
    func deploy() async throws -> (Build, UUID) {
        let buildID = UUID()
        let number = try await numbers.reserve(app: app, buildID: buildID)
        let action = WorkflowAction(scheme: "App", platform: .iOS, export: .appStoreConnect)
        let job = Job(id: UUID(), buildID: buildID, action: action, status: .queued, createdAt: now)
        let build = Build(
            id: buildID, appID: app.id, workflow: "release", ref: "main", commit: "abc", buildNumber: number,
            status: .queued, createdAt: now, jobs: [job])
        try builds.insert(build, workflow: Workflow(project: "App.xcodeproj", xcode: "27.2", actions: [action]))
        return (build, job.id)
    }

    /// Every event published so far on `stream`: publishes a sentinel and collects up to it.
    func drain(_ stream: AsyncStream<EventBus.Event>) async -> [ServerEvent] {
        let sentinel = Machine(id: UUID(), name: "sentinel", createdAt: Self.start)
        events.publish(.server(.machine(sentinel)))
        var collected: [ServerEvent] = []
        for await event in stream {
            guard case .server(let server) = event else { continue }
            if server == .machine(sentinel) { break }
            collected.append(server)
        }
        return collected
    }

    /// Waits for the first job event matching `predicate`.
    func next(
        _ iterator: inout AsyncStream<EventBus.Event>.Iterator, where predicate: (Job) -> Bool
    ) async -> Job? {
        while let event = await iterator.next() {
            if case .server(.job(let job)) = event, predicate(job) { return job }
        }
        return nil
    }

    @Test func assignsAndPublishes() async throws {
        var iterator = events.subscribe().makeAsyncIterator()
        let running = Task { await loop.run() }
        defer { running.cancel() }

        let (build, jobID) = try await deploy()
        loop.poke()
        let assigned = try #require(await next(&iterator) { $0.id == jobID && $0.status == .assigned })
        #expect(assigned.machineID == macBook.id)
        #expect(assigned.assignedAt == now)
        #expect(assigned.queueNote == nil)
        #expect(try builds.build(id: build.id)?.status == .running)

        // The loop is now waiting; with the clock standing still only a poke can wake it.
        let mini = try machines.create(name: "Mac mini").0
        try report(mini)
        let (_, secondID) = try await deploy()
        loop.poke()
        let second = try #require(await next(&iterator) { $0.id == secondID && $0.status == .assigned })
        #expect(second.machineID == mini.id)

        // Without a poke the next tick comes after `tickInterval` on the clock.
        let studio = try machines.create(name: "Mac Studio").0
        try report(studio)
        let (_, thirdID) = try await deploy()
        let ticking = Task {
            for _ in 0..<100 {
                await clock.advance(by: .seconds(2))
                await Task.yield()
            }
        }
        defer { ticking.cancel() }
        let third = try #require(await next(&iterator) { $0.id == thirdID && $0.status == .assigned })
        #expect(third.machineID == studio.id)
    }

    @Test func anIndividualKeysArchiveWaitsForAMacWithAnXcodeAccount() async throws {
        let asked = Mutex<[UUID]>([])
        let current = current
        let loop = SchedulerLoop(
            builds: builds, machines: machines, events: events, config: SchedulerConfig(), clock: clock,
            now: { current.date }, teamKey: { appID in asked.withLock { $0.append(appID) }; return false })
        try report(macBook, headless: true)
        let (_, jobID) = try await deploy()
        try await loop.tick()
        let waiting = try #require(try builds.job(id: jobID))
        #expect(waiting.status == .queued)
        #expect(waiting.queueNote
            == "MacBook Pro: needs a team App Store Connect key (with an issuer ID): this Mac's worker runs without an Xcode account")
        #expect(asked.withLock { $0 } == [app.id])

        let laptop = try machines.create(name: "Laptop").0
        try report(laptop)
        try await loop.tick()
        #expect(try builds.job(id: jobID)?.machineID == laptop.id)
    }

    @Test func failsRunningJobWhenMachineSilentFor120s() async throws {
        let stream = events.subscribe()
        let (build, jobID) = try await deploy()
        #expect(build.buildNumber == 301)
        try await loop.tick()
        #expect(try builds.job(id: jobID)?.status == .assigned)
        try builds.setJobStatus(id: jobID, status: .running, at: now)
        _ = await drain(stream)

        await advance(seconds: 100)
        try await loop.tick()
        #expect(try builds.job(id: jobID)?.status == .running)

        await advance(seconds: 21)
        try await loop.tick()
        let failed = try #require(try builds.job(id: jobID))
        #expect(failed.status == .failed)
        #expect(failed.failureReason == "worker lost: MacBook Pro stopped reporting")
        #expect(failed.finishedAt == now)
        let refreshed = try #require(try builds.build(id: build.id))
        #expect(refreshed.status == .failed)
        let published = await drain(stream)
        #expect(published.contains(.job(failed)))
        #expect(published.contains(.build(refreshed)))

        // The failed build burns its number: the next deploy gets a higher one.
        let (next, _) = try await deploy()
        #expect(next.buildNumber == 302)
    }

    @Test func lostMachineAssignedJobFailsRatherThanRequeues() async throws {
        // A machine timeout below the online window makes the machine both "online" and lost at 61 s.
        let loop = SchedulerLoop(
            builds: builds, machines: machines, events: events, config: SchedulerConfig(machineTimeout: 30),
            clock: clock, now: { [current] in current.date })
        let (_, jobID) = try await deploy()
        try await loop.tick()
        await advance(seconds: 61)
        try await loop.tick()
        let job = try #require(try builds.job(id: jobID))
        #expect(job.status == .failed)
        #expect(job.failureReason == "worker lost: MacBook Pro stopped reporting")
    }

    @Test func requeuesAssignedJobNotStartedWithin60s() async throws {
        let stream = events.subscribe()
        let (_, jobID) = try await deploy()
        try await loop.tick()
        let assignedAt = now
        #expect(try builds.job(id: jobID)?.status == .assigned)

        await advance(seconds: 59)
        try report(macBook)
        try await loop.tick()
        #expect(try builds.job(id: jobID)?.assignedAt == assignedAt)
        _ = await drain(stream)

        // Still reporting, but now short of disk: the job goes back to the queue and waits.
        await advance(seconds: 2)
        try report(macBook, freeDiskGB: 12)
        try await loop.tick()
        let job = try #require(try builds.job(id: jobID))
        #expect(job.status == .queued)
        #expect(job.machineID == nil)
        #expect(job.queueNote == "MacBook Pro: only 12 GB free (needs 20 GB)")
        let published = await drain(stream)
        #expect(published.contains(.job(job)))
        #expect(published.contains { if case .job(let j) = $0 { j.id == jobID && j.queueNote == nil } else { false } })
        #expect(try builds.build(id: job.buildID)?.status == .queued)
    }

    @Test func waitingNoteIsPublishedOnceAndNoMachinesIsExplained() async throws {
        try machines.delete(id: macBook.id)
        let stream = events.subscribe()
        let (_, jobID) = try await deploy()
        try await loop.tick()
        try await loop.tick()
        #expect(try builds.job(id: jobID)?.queueNote == "no machines registered")
        let published = await drain(stream)
        #expect(published.count { if case .job = $0 { true } else { false } } == 1)
    }

    @Test func assignIsNotDoubled() async throws {
        let stream = events.subscribe()
        let (_, jobID) = try await deploy()
        async let first: Void = loop.tick()
        async let second: Void = loop.tick()
        _ = try await (first, second)
        #expect(try builds.job(id: jobID)?.status == .assigned)
        let assignments = await drain(stream).filter {
            if case .job(let job) = $0 { job.id == jobID && job.status == .assigned } else { false }
        }
        #expect(assignments.count == 1)
    }

    @Test func aPausedMacFinishesItsJobTakesNoNewOneAndResumes() async throws {
        let (_, firstID) = try await deploy()
        try await loop.tick()
        #expect(try builds.job(id: firstID)?.machineID == macBook.id)
        try builds.setJobStatus(id: firstID, status: .running, at: now)

        _ = try machines.setPaused(id: macBook.id, true)
        let (_, secondID) = try await deploy()
        try await loop.tick()
        #expect(try builds.job(id: secondID)?.queueNote == "MacBook Pro: builds paused, busy")

        // Still reporting while paused: the running job is not lost.
        await advance(seconds: 100)
        try report(macBook)
        try await loop.tick()
        #expect(try builds.job(id: firstID)?.status == .running)
        try builds.setJobStatus(id: firstID, status: .succeeded, at: now)
        try await loop.tick()
        let waiting = try #require(try builds.job(id: secondID))
        #expect(waiting.status == .queued)
        #expect(waiting.queueNote == "MacBook Pro: builds paused")

        _ = try machines.setPaused(id: macBook.id, false)
        try await loop.tick()
        let assigned = try #require(try builds.job(id: secondID))
        #expect(assigned.status == .assigned && assigned.machineID == macBook.id && assigned.queueNote == nil)
    }

    @Test func aVMMacTakesAJobPerReadySlotAndExplainsWhenItHasNone() async throws {
        let image = VMImageInfo(name: "xcode-27.2", macOS: "26.6.2", xcode: "27.2")
        try report(macBook, vm: VMReport(
            slots: 0, configuredSlots: 2, freeSlots: 0, storageFreeGB: 150, networkFilter: false,
            problem: "the network filter is not installed", images: [image]))
        let (_, firstID) = try await deploy()
        let (_, secondID) = try await deploy()
        try await loop.tick()
        #expect(try builds.job(id: firstID)?.status == .queued)
        #expect(try builds.job(id: firstID)?.queueNote == "MacBook Pro: VM builds not ready: the network filter is not installed")

        // Two ready slots take two jobs, though the machine's own limit is one.
        try report(macBook, vm: VMReport(
            slots: 2, configuredSlots: 2, freeSlots: 2, storageFreeGB: 150, networkFilter: true, images: [image]))
        try await loop.tick()
        for id in [firstID, secondID] {
            let job = try #require(try builds.job(id: id))
            #expect(job.status == .assigned && job.machineID == macBook.id && job.queueNote == nil)
        }
    }
}
