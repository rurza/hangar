import Foundation
import HangarCore
import Logging

public struct SchedulerConfig: Sendable {
    public var minFreeDiskGB: Double
    /// A machine silent this long loses its assigned and running jobs.
    public var machineTimeout: TimeInterval
    /// An assigned job not started this long goes back to the queue.
    public var assignmentTimeout: TimeInterval
    public var tickInterval: Duration

    public init(
        minFreeDiskGB: Double = 20, machineTimeout: TimeInterval = 120, assignmentTimeout: TimeInterval = 60,
        tickInterval: Duration = .seconds(2)
    ) {
        self.minFreeDiskGB = minFreeDiskGB
        self.machineTimeout = machineTimeout
        self.assignmentTimeout = assignmentTimeout
        self.tickInterval = tickInterval
    }
}

/// Assigns queued jobs to machines, fails jobs of machines that stopped reporting and requeues
/// assignments nobody picked up. Every change is published on the event bus.
public actor SchedulerLoop {
    let builds: BuildRepository
    let machines: MachineRepository
    let events: EventBus
    let config: SchedulerConfig
    let clock: any Clock<Duration>
    let now: @Sendable () -> Date
    /// Whether the App Store Connect key a build of this app gets is a team key (it has an issuer ID).
    let teamKey: @Sendable (_ appID: UUID) -> Bool
    private let logger = Logger(label: "app.hangar.server.scheduler")
    private let wakes: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation

    public init(
        builds: BuildRepository, machines: MachineRepository, events: EventBus, config: SchedulerConfig = .init(),
        clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = Date.init,
        teamKey: @escaping @Sendable (_ appID: UUID) -> Bool = { _ in true }
    ) {
        self.teamKey = teamKey
        self.builds = builds
        self.machines = machines
        self.events = events
        self.config = config
        self.clock = clock
        self.now = now
        // Newest(1): pokes arriving during a tick collapse into one extra tick instead of being lost.
        (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Asks for a tick now (e.g. after a deploy or a worker report) instead of at the next interval.
    public nonisolated func poke() { wake.yield() }

    /// Ticks immediately, then on every `tickInterval` and every poke, until the task is cancelled.
    public func run() async {
        let timer = Task { [clock, config, wake] in
            while true {
                do { try await clock.sleep(for: config.tickInterval) } catch { return }
                wake.yield()
            }
        }
        defer { timer.cancel() }
        await tickLogged()
        for await _ in wakes { await tickLogged() }
    }

    /// No suspension points inside, so ticks never interleave on the actor; `assign`'s conditional
    /// update still guards against any other writer.
    public func tick() async throws {
        let now = now()
        let all = try machines.all()
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        // Worker loss before requeue: a lost machine's assigned job fails rather than going back to the queue.
        try failJobsOfLostMachines(byID, now: now)
        try requeueStaleAssignments(byID, now: now)
        try assignQueuedJobs(all, now: now)
    }

    private func tickLogged() async {
        do { try await tick() } catch { logger.error("scheduler tick failed: \(error)") }
    }

    private func failJobsOfLostMachines(_ machines: [UUID: Machine], now: Date) throws {
        for job in try builds.jobs(status: [.assigned, .running]) {
            guard let machineID = job.machineID else { continue }
            let machine = machines[machineID]
            if let seen = machine?.lastSeenAt, now.timeIntervalSince(seen) <= config.machineTimeout { continue }
            let name = machine?.name ?? machineID.uuidString
            // Conditional: a job that finished meanwhile keeps its result.
            guard try builds.transitionJob(
                id: job.id, from: [.assigned, .running], to: .failed, at: now,
                failureReason: "worker lost: \(name) stopped reporting")
            else { continue }
            try publishChange(jobID: job.id, buildID: job.buildID)
        }
    }

    private func requeueStaleAssignments(_ machines: [UUID: Machine], now: Date) throws {
        for job in try builds.jobs(status: [.assigned]) {
            guard let assignedAt = job.assignedAt, now.timeIntervalSince(assignedAt) > config.assignmentTimeout,
                let machineID = job.machineID, machines[machineID]?.isOnline(now: now) == true,
                try builds.unassign(jobID: job.id)
            else { continue }
            try publishChange(jobID: job.id, buildID: job.buildID)
        }
    }

    private func assignQueuedJobs(_ machines: [Machine], now: Date) throws {
        let running = try Self.runningCounts(builds)
        let snapshots = machines.map { Self.snapshot($0, runningJobs: running[$0.id] ?? 0, now: now) }

        let queued = try builds.jobs(status: [.queued])
        var requirements: [UUID: (workflow: Workflow?, pinned: UUID?, teamKey: Bool)] = [:]
        var candidates: [QueuedJob] = []
        for job in queued {
            if requirements[job.buildID] == nil {
                let build = try builds.build(id: job.buildID)
                requirements[job.buildID] = (
                    try builds.workflow(buildID: job.buildID), build?.pinnedMachineID, build.map { teamKey($0.appID) } ?? true
                )
            }
            guard let (workflow, pinned, teamKey) = requirements[job.buildID], let workflow else {
                // Only builds inserted before workflows were stored lack one; they can never be matched.
                if try builds.transitionJob(
                    id: job.id, from: [.queued], to: .failed, at: now, failureReason: "build has no stored workflow")
                {
                    try publishChange(jobID: job.id, buildID: job.buildID)
                }
                continue
            }
            candidates.append(
                Self.queuedJob(
                    id: job.id, buildID: job.buildID, createdAt: job.createdAt, action: job.action, workflow: workflow,
                    pinned: pinned, teamKey: teamKey))
        }

        let plan = Scheduler.plan(jobs: candidates, machines: snapshots, minFreeDiskGB: config.minFreeDiskGB)
        let byID = Dictionary(uniqueKeysWithValues: queued.map { ($0.id, $0) })
        for assignment in plan.assignments {
            guard let job = byID[assignment.jobID],
                try builds.assign(jobID: job.id, to: assignment.machineID, at: now)
            else { continue }
            if job.queueNote != nil { try builds.setQueueNote(jobID: job.id, note: nil) }
            try publishChange(jobID: job.id, buildID: job.buildID)
        }
        for (jobID, reasons) in plan.waiting {
            let note = Scheduler.queueNote(reasons)
            guard let job = byID[jobID], job.queueNote != note else { continue }
            try builds.setQueueNote(jobID: jobID, note: note)
            if let updated = try builds.job(id: jobID) { events.publish(.server(.job(updated))) }
        }
    }

    /// Publishes the job and its build, re-deriving the build's status first.
    private func publishChange(jobID: UUID, buildID: UUID) throws {
        if let job = try builds.job(id: jobID) { events.publish(.server(.job(job))) }
        events.publish(.server(.build(try builds.refreshBuildStatus(buildID: buildID))))
    }

    /// The job as the scheduler judges it: what its action needs of a machine. Shared with the deploy dry run.
    /// `teamKey`: the app's App Store Connect key has an issuer ID.
    static func queuedJob(
        id: UUID, buildID: UUID, createdAt: Date, action: WorkflowAction, workflow: Workflow, pinned: UUID?,
        teamKey: Bool
    ) -> QueuedJob {
        QueuedJob(
            id: id, buildID: buildID, createdAt: createdAt, xcode: workflow.xcode, tools: workflow.tools,
            pinnedMachineID: pinned,
            simulatorPlatform: action.kind == .test && action.platform != .macOS ? action.platform : nil,
            requiredCapabilities: workflow.needsCapabilities(for: action),
            needsXcodeAccount: action.kind == .archive && !teamKey)
    }

    /// Whether `entries` (an app's resolved variables) hold a team key: a non-empty `HANGAR_ASC_ISSUER_ID`, as the
    /// worker reads it (`ASCKeyArguments`).
    static func hasTeamKey(_ entries: [EnvEntry]) -> Bool {
        entries.contains { $0.name == "HANGAR_ASC_ISSUER_ID" && !$0.value.isEmpty }
    }

    /// Machine id → its assigned and running jobs, as a tick counts them.
    static func runningCounts(_ builds: BuildRepository) throws -> [UUID: Int] {
        let active = try builds.jobs(status: [.assigned, .running]).compactMap(\.machineID)
        return Dictionary(grouping: active, by: { $0 }).mapValues(\.count)
    }

    /// Machines without a report are offline for scheduling.
    static func snapshot(_ machine: Machine, runningJobs: Int, now: Date) -> MachineSnapshot {
        let freeSlots = max(0, machine.maxConcurrentJobs - runningJobs)
        guard let report = machine.report else {
            return MachineSnapshot(
                id: machine.id, name: machine.name, isOnline: false, freeSlots: freeSlots, runningJobs: runningJobs,
                xcodeVersions: [], tools: [], freeDiskGB: 0, performanceCores: 0, onACPower: false, canSign: false,
                paused: machine.paused)
        }
        return MachineSnapshot(
            id: machine.id, name: machine.name, isOnline: machine.isOnline(now: now), freeSlots: freeSlots,
            runningJobs: runningJobs, xcodeVersions: report.xcodes.map(\.version), tools: Set(report.tools.keys),
            freeDiskGB: report.freeDiskGB, performanceCores: report.performanceCores, onACPower: report.onACPower,
            canSign: report.canSignWithoutPrompt, simulatorRuntimes: report.simulatorRuntimes,
            capabilities: Set(report.capabilities), headless: report.headless ?? false, paused: machine.paused)
    }
}
