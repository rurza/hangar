import Foundation
import HangarCore
import Logging
import Synchronization

/// What the loop needs from `JobRunner`; a seam so loop tests need no real builds.
public protocol JobRunning: Sendable {
    func run(_ assignment: JobAssignment, cancelled: @escaping @Sendable () -> Bool) async -> JobResult
}

extension JobRunner: JobRunning {}

/// The worker daemon: a heartbeat loop and a pull loop that run until the task is cancelled.
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
    private let logger = Logger(label: "app.hangar.worker")
    private let jobs = RunningJobs()
    /// The hash of a worker update that failed, and when it may be tried again. One bad download does not retry on
    /// every heartbeat.
    private var updateHoldoff: (sha256: String, until: ContinuousClock.Instant)?
    private var updating = false

    public init(
        configuration: WorkerConfiguration, connection: any ServerConnection, doctor: Doctor, jobRunner: any JobRunning,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.configuration = configuration
        self.connection = connection
        self.doctor = doctor
        self.jobRunner = jobRunner
        self.clock = clock
    }

    /// Returns once the surrounding task is cancelled and the jobs in flight have ended.
    public func run() async {
        prepareDataDirectory()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.heartbeatLoop() }
            group.addTask { await self.pullLoop() }
            await group.waitForAll()
        }
    }

    // MARK: Start-up

    /// Creates the data directory at mode 0700 and removes what a crashed run left in `jobs/`: each job's secrets are
    /// wiped first.
    private func prepareDataDirectory() {
        guard Self.createPrivateDataDirectory(configuration.dataDirectory, logger: logger) else { return }
        let root = URL(fileURLWithPath: configuration.dataDirectory).standardizedFileURL.path
        let jobsDirectory = root + "/jobs"
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

    /// Creates `path` if needed and sets it to mode 0700 with a real `chmod`: the create attribute is subject to umask
    /// and does not change a directory that already exists. Does not walk the cache inside it. False when the
    /// directory cannot be created; a failed chmod is only logged.
    @discardableResult
    static func createPrivateDataDirectory(_ path: String, logger: Logger) -> Bool {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            logger.error("could not create the data directory \(root): \(error)")
            return false
        }
        do {
            try WorkerPrivacy.setMode(0o700, at: root)
        } catch {
            logger.warning("could not set the data directory \(root) to mode 0700: \(error)")
        }
        return true
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
            while !Task.isCancelled {
                if running >= max(configuration.maxConcurrentJobs, 1) {
                    await group.next()
                    running -= 1
                    continue
                }
                do {
                    let assignment = try await connection.nextJob(wait: Self.pollWait)
                    backoff.reset()
                    guard let assignment else { continue }
                    running += 1
                    let id = assignment.job.id
                    jobs.begin(id)
                    group.addTask { [jobs, jobRunner, logger] in
                        let result = await jobRunner.run(assignment, cancelled: { jobs.isCancelled(id) })
                        jobs.end(id)
                        logger.info("job ended", metadata: ["job": "\(id)", "status": "\(result.status.rawValue)"])
                    }
                } catch {
                    let delay = backoff.next()
                    if Task.isCancelled { break }
                    logger.error("could not fetch a job: \(error); retrying in \(delay)")
                    await sleep(delay)
                }
            }
            await group.waitForAll()
        }
    }

    private func sleep(_ duration: Duration) async {
        try? await clock.sleep(for: duration)
    }

    /// Downloads the server's `hangar-worker` and re-executes into it when this process is idle. A job that is
    /// running, or that starts while the download is in flight, keeps this binary: the restart would forget the job.
    private func applyUpdate(_ update: WorkerUpdate) async {
        guard !updating, jobs.runningIDs.isEmpty else { return }
        guard update.sha256 != WorkerSelfUpdate.executableSHA256 else { return }
        if let holdoff = updateHoldoff, holdoff.sha256 == update.sha256, ContinuousClock.now < holdoff.until { return }
        updating = true
        defer { updating = false }
        do {
            let data = try await WorkerSelfUpdate.download(from: configuration.serverURL)
            guard jobs.runningIDs.isEmpty, let executable = Bundle.main.executableURL else { return }
            let staged = try WorkerSelfUpdate.stage(data, sha256: update.sha256, nextTo: executable)
            guard jobs.runningIDs.isEmpty else {
                try? FileManager.default.removeItem(at: staged)
                return
            }
            try WorkerSelfUpdate.replace(executable, with: staged)
            logger.info("updated hangar-worker; restarting into it")
            if !WorkerSelfUpdate.relaunch() {
                logger.error("could not restart into the updated hangar-worker")
            }
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
    }

    private let state = Mutex(State())

    var runningIDs: [UUID] { state.withLock { $0.running } }

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
