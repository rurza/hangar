import Foundation
import HangarCore
import Logging
import Synchronization

/// What the loop needs from `JobRunner`; a seam so loop tests need no real builds.
public protocol JobRunning: Sendable {
    /// `stopReason` is set once the worker itself cancels the job because it is shutting down.
    func run(
        _ assignment: JobAssignment, cancelled: @escaping @Sendable () -> Bool,
        stopReason: @escaping @Sendable () -> String?
    ) async -> JobResult
}

extension JobRunner: JobRunning {}

/// Fetches and installs a new `hangar-worker`; a seam so loop tests neither download nor re-execute.
public protocol WorkerUpdating: Sendable {
    func download(from server: URL) async throws -> Data
    /// Verifies `data` against `sha256`, puts it in place of the running binary and re-executes into it. Returns
    /// only when that fails.
    func install(_ data: Data, sha256: String) throws
}

/// The real thing: `WorkerSelfUpdate`.
public struct LiveWorkerUpdater: WorkerUpdating {
    public init() {}

    public func download(from server: URL) async throws -> Data {
        try await WorkerSelfUpdate.download(from: server)
    }

    public func install(_ data: Data, sha256: String) throws {
        guard let executable = Bundle.main.executableURL else { throw WorkerSelfUpdate.Failure.unwritable("hangar-worker") }
        let staged = try WorkerSelfUpdate.stage(data, sha256: sha256, nextTo: executable)
        try WorkerSelfUpdate.replace(executable, with: staged)
        Logger(label: "app.hangar.worker").info("updated hangar-worker; restarting into it")
        if !WorkerSelfUpdate.relaunch() { throw WorkerSelfUpdate.Failure.unwritable(executable.path) }
    }
}

/// The worker daemon: a heartbeat loop and a pull loop that run until the task is cancelled or `stop(reason:)`.
///
/// `stop(reason:)` (SIGTERM) stops asking for jobs, raises the cancel flag of every running job with the reason, and
/// returns from `run()` once they have reported their result and cleaned up. A long poll in flight is cancelled: a job
/// the server assigned meanwhile stays assigned there and is handed to the worker's next run.
///
/// A worker update only re-executes while nothing runs and no poll is in flight: polling pauses while the update
/// downloads, the poll in flight is cancelled and waited for, and a job it still brought back is run instead (the
/// update is then dropped until the next heartbeat offers it again).
///
/// The heartbeat reports this machine's health and running jobs every 30 s and raises the cancel flag of every job
/// the server names. The pull loop long-polls for a job while fewer than `maxConcurrentJobs` run and hands each one to
/// `JobRunner`, which reports the job's start, steps and result itself. Transport errors are logged and retried with
/// a 5 s → 60 s exponential backoff per loop, reset by the next success. Nothing a job does stops the loop.
public actor WorkerLoop {
    static let heartbeatInterval = Duration.seconds(30)
    static let pollWait = 25

    private let configuration: WorkerConfiguration
    private let connection: any ServerConnection
    private let doctor: Doctor
    private let jobRunner: any JobRunning
    private let clock: any Clock<Duration>
    private let temporaryRoot: String
    private let logger = Logger(label: "app.hangar.worker")
    private let jobs = RunningJobs()
    /// The hash of a worker update that failed, and when it may be tried again. One bad download does not retry on
    /// every heartbeat.
    private var updateHoldoff: (sha256: String, until: ContinuousClock.Instant)?
    private let updater: any WorkerUpdating
    /// An update is downloading or about to re-execute: the pull loop starts no poll meanwhile.
    private var updating = false
    /// Why the worker is stopping; set once by `stop(reason:)`.
    private var stopReason: String?
    /// The long poll in flight, cancelled by a stop or an update.
    private var pollTask: Task<JobAssignment?, any Error>?
    /// The pull loop's backoff sleep, cut short by a stop.
    private var pauseTask: Task<Void, Never>?
    /// Who waits for the poll in flight to end, or for an update to be over.
    private var pollWaiters: [CheckedContinuation<Void, Never>] = []
    private var updateWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        configuration: WorkerConfiguration, connection: any ServerConnection, doctor: Doctor, jobRunner: any JobRunning,
        clock: any Clock<Duration> = ContinuousClock(), temporaryRoot: String? = nil,
        updater: any WorkerUpdating = LiveWorkerUpdater()
    ) {
        self.updater = updater
        self.temporaryRoot = temporaryRoot ?? WorkspaceLayout.temporaryRoot(dataDirectory: configuration.resolvedWorkDirectory)
        self.configuration = configuration
        self.connection = connection
        self.doctor = doctor
        self.jobRunner = jobRunner
        self.clock = clock
    }

    /// Returns once the surrounding task is cancelled, or `stop(reason:)` was called, and the jobs in flight have
    /// ended.
    public func run() async {
        prepareDataDirectory()
        await withTaskGroup(of: Void.self) { group in
            // The heartbeat keeps reporting the jobs that are winding down; it ends with the pull loop.
            group.addTask { await self.heartbeatLoop() }
            await pullLoop()
            group.cancelAll()
        }
    }

    /// Stops the worker gracefully: no new jobs, and every running job is cancelled with `reason` ("hangar-worker on
    /// rurzomac-mini was stopped (SIGTERM)"), which it reports as its result. `run()` returns when they have ended.
    public func stop(reason: String) {
        guard stopReason == nil else { return }
        stopReason = reason
        let running = jobs.runningIDs
        logger.notice("stopping: \(reason); cancelling \(running.count) running job(s)")
        jobs.stopAll(reason: reason)
        pollTask?.cancel()
        pauseTask?.cancel()
        resumeAll(&updateWaiters)
    }

    // MARK: Start-up

    /// Creates the work directory, moves the workspaces into it from the data directory the first time they differ,
    /// and removes what a crashed run left in `jobs/` (of either): each job's secrets are wiped first.
    private func prepareDataDirectory() {
        let data = URL(fileURLWithPath: configuration.dataDirectory).standardizedFileURL.path
        let work = configuration.resolvedWorkDirectory
        do {
            try FileManager.default.createDirectory(
                atPath: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            logger.error("could not create the work directory \(work): \(error)")
            return
        }
        if work.contains(where: \.isWhitespace) {
            logger.warning("the work directory \(work) has a space in its path; scripts written for Xcode Cloud may break")
        }
        do {
            for line in try WorkDirectoryMigration.run(from: data, to: work) { logger.info("\(line)") }
        } catch {
            logger.error("could not move the workspaces from \(data) to \(work): \(error); the next builds start cold")
        }
        sweepTemporaryDirectories()
        for root in Set([work, data]).sorted() { sweepJobDirectories(in: root + "/jobs") }
    }

    private func sweepJobDirectories(in jobsDirectory: String) {
        guard let leftovers = try? FileManager.default.contentsOfDirectory(atPath: jobsDirectory) else { return }
        for name in leftovers.sorted() {
            let path = jobsDirectory + "/" + name
            do {
                try SecretsMaterializer(directory: path + "/secrets").wipe()
                try SafeRemoval.removeItem(atPath: path, within: jobsDirectory)
                logger.info("swept leftover job directory \(name)")
            } catch {
                logger.error("could not sweep leftover job directory \(name): \(error)")
            }
        }
    }

    /// Removes the `TMPDIR`s of jobs a crashed run left in `<work directory>/tmp`.
    private func sweepTemporaryDirectories() {
        let root = URL(fileURLWithPath: temporaryRoot).standardizedFileURL.path
        guard let leftovers = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for name in leftovers.sorted() {
            do {
                try SafeRemoval.removeItem(atPath: root + "/" + name, within: root)
                logger.info("swept leftover temporary directory \(name)")
            } catch {
                logger.error("could not sweep leftover temporary directory \(name): \(error)")
            }
        }
    }

    // MARK: Loops

    private func heartbeatLoop() async {
        var backoff = Backoff()
        while !Task.isCancelled {
            do {
                var report = await doctor.report(runningJobIDs: jobs.runningIDs)
                report.binarySHA256 = WorkerSelfUpdate.executableSHA256
                let response = try await connection.heartbeat(HeartbeatRequest(report: report))
                backoff.reset()
                jobs.cancel(response.cancelJobIDs)
                if let update = response.workerUpdate { Task { await self.applyUpdate(update) } }
                await sleep(Self.heartbeatInterval)
            } catch {
                if Task.isCancelled { break }
                let delay = backoff.next()
                logger.error("heartbeat failed: \(error); retrying in \(delay)")
                await sleep(delay)
            }
        }
    }

    private func pullLoop() async {
        var backoff = Backoff()
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while !Task.isCancelled, stopReason == nil {
                if running >= max(configuration.maxConcurrentJobs, 1) {
                    await group.next()
                    running -= 1
                    continue
                }
                if updating {
                    await withCheckedContinuation { updateWaiters.append($0) }
                    continue
                }
                let poll = Task { [connection] in try await connection.nextJob(wait: Self.pollWait) }
                pollTask = poll
                let outcome = await withTaskCancellationHandler { await poll.result } onCancel: { poll.cancel() }
                // Nothing suspends from here until the waiters are resumed: whoever waits for the poll to end sees
                // its job already registered as running.
                pollTask = nil
                var pause: Duration?
                switch outcome {
                case .success(let assignment?):
                    backoff.reset()
                    if stopReason != nil {
                        // It stays assigned on the server and goes to the worker's next run.
                        logger.info("not starting a job while stopping", metadata: ["job": "\(assignment.job.id)"])
                    } else {
                        running += 1
                        let id = assignment.job.id
                        jobs.begin(id)
                        group.addTask { [jobs, jobRunner, logger] in
                            let result = await jobRunner.run(
                                assignment, cancelled: { jobs.isCancelled(id) }, stopReason: { jobs.stopReason })
                            jobs.end(id)
                            logger.info("job ended", metadata: ["job": "\(id)", "status": "\(result.status.rawValue)"])
                        }
                    }
                case .success(nil):
                    backoff.reset()
                case .failure(let error):
                    // A stop or an update cancelled the poll: no backoff.
                    let interrupted = error is CancellationError || (error as? URLError)?.code == .cancelled
                    if !Task.isCancelled, stopReason == nil, !interrupted {
                        let delay = backoff.next()
                        logger.error("could not fetch a job: \(error); retrying in \(delay)")
                        pause = delay
                    }
                }
                resumeAll(&pollWaiters)
                if let pause {
                    let task = Task { [clock] in _ = try? await clock.sleep(for: pause) }
                    pauseTask = task
                    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                    pauseTask = nil
                }
            }
            await group.waitForAll()
        }
    }

    private func resumeAll(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Cancels the poll in flight, if any, and returns once the pull loop has dealt with its outcome.
    private func endPollInFlight() async {
        guard let poll = pollTask else { return }
        poll.cancel()
        await withCheckedContinuation { pollWaiters.append($0) }
    }

    private func sleep(_ duration: Duration) async {
        try? await clock.sleep(for: duration)
    }

    /// Downloads the server's `hangar-worker` and re-executes into it when this process is idle. A job that is
    /// running, or that a poll brings back while the update is under way, keeps this binary: the restart would forget
    /// the job.
    private func applyUpdate(_ update: WorkerUpdate) async {
        guard !updating, stopReason == nil, jobs.runningIDs.isEmpty else { return }
        guard update.sha256 != WorkerSelfUpdate.executableSHA256 else { return }
        if let holdoff = updateHoldoff, holdoff.sha256 == update.sha256, ContinuousClock.now < holdoff.until { return }
        updating = true
        defer {
            updating = false
            resumeAll(&updateWaiters)
        }
        do {
            let data = try await updater.download(from: configuration.serverURL)
            await endPollInFlight()
            guard jobs.runningIDs.isEmpty, stopReason == nil else {
                logger.info("not updating hangar-worker: a job started meanwhile")
                return
            }
            try updater.install(data, sha256: update.sha256)
        } catch {
            updateHoldoff = (update.sha256, ContinuousClock.now.advanced(by: .seconds(300)))
            logger.error("worker update failed: \(error)")
        }
    }
}

/// 5 s, 10 s, 20 s … capped at 60 s.
struct Backoff {
    private var failures = 0

    mutating func next() -> Duration {
        failures += 1
        return .seconds(min(5 * (1 << min(failures - 1, 10)), 60))
    }

    mutating func reset() { failures = 0 }
}

/// The jobs in flight and their cancel flags. Read synchronously by each job's `cancelled` closure.
private final class RunningJobs: Sendable {
    private struct State {
        var running: [UUID] = []
        var cancelled: Set<UUID> = []
        var stopReason: String?
    }

    private let state = Mutex(State())

    var runningIDs: [UUID] { state.withLock { $0.running } }

    /// Set once the worker is stopping; every job then reports it.
    var stopReason: String? { state.withLock { $0.stopReason } }

    /// Flags every running job, with the reason the worker is stopping.
    func stopAll(reason: String) {
        state.withLock { state in
            state.stopReason = reason
            state.cancelled.formUnion(state.running)
        }
    }

    func begin(_ id: UUID) { state.withLock { $0.running.append(id) } }

    func end(_ id: UUID) {
        state.withLock {
            $0.running.removeAll { $0 == id }
            $0.cancelled.remove(id)
        }
    }

    /// Flags only jobs that are running here; the server may name a job that just ended.
    func cancel(_ ids: [UUID]) {
        state.withLock { state in
            for id in ids where state.running.contains(id) { state.cancelled.insert(id) }
        }
    }

    func isCancelled(_ id: UUID) -> Bool { state.withLock { $0.cancelled.contains(id) } }
}
