import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarWorker

/// A clock that only moves when the test advances it. Every sleep is recorded (as its requested duration) in the same
/// step that registers it, so a test that has seen a sleep recorded can advance without racing the sleeper.
private final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UUID: Sleeper] = [:]
        var requested: [Duration] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    /// Every duration a sleep was started with, in order.
    var requested: [Duration] { state.withLock { $0.requested } }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Decision { case cancelled, immediate, registered }
                let decision = state.withLock { state -> Decision in
                    if Task.isCancelled { return .cancelled }
                    if deadline <= state.now { return .immediate }
                    state.requested.append(state.now.duration(to: deadline))
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .registered
                }
                switch decision {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .immediate: continuation.resume()
                case .registered: break  // advance(by:) or onCancel resumes it, whichever removes it first.
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let ids = state.sleepers.filter { $0.value.deadline <= state.now }.map(\.key)
            return ids.compactMap { state.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Scripts what the server answers to `nextJob` and `heartbeat`, and records the calls.
private final class ScriptedConnection: ServerConnection {
    enum Answer {
        case job(JobAssignment)
        case nothing
        case failure
        /// Waits like a long poll; when cancelled, returns the job anyway: its response was already on the way.
        case jobWhenCancelled(JobAssignment)
    }

    struct Unavailable: Error {}

    private struct State {
        var answers: [Answer]
        var heartbeatResponses: [HeartbeatResponse]
        var nextJobCalls = 0
        var heartbeats: [HeartbeatRequest] = []
    }

    private let state: Mutex<State>

    /// Answers `nextJob` in order; once they run out, `nextJob` waits until cancelled, like a long poll.
    init(answers: [Answer] = [], heartbeatResponses: [HeartbeatResponse] = []) {
        state = Mutex(State(answers: answers, heartbeatResponses: heartbeatResponses))
    }

    var nextJobCalls: Int { state.withLock { $0.nextJobCalls } }
    var heartbeats: [HeartbeatRequest] { state.withLock { $0.heartbeats } }

    func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse {
        state.withLock {
            $0.heartbeats.append(request)
            return $0.heartbeatResponses.isEmpty ? HeartbeatResponse() : $0.heartbeatResponses.removeFirst()
        }
    }

    func nextJob(wait: Int) async throws -> JobAssignment? {
        let answer = state.withLock { state -> Answer? in
            state.nextJobCalls += 1
            return state.answers.isEmpty ? nil : state.answers.removeFirst()
        }
        switch answer {
        case .job(let assignment): return assignment
        case .nothing: return nil
        case .failure: throw Unavailable()
        case .jobWhenCancelled(let assignment):
            try? await Task.sleep(for: .seconds(3600))
            return assignment
        case nil:
            try await Task.sleep(for: .seconds(3600))
            return nil
        }
    }

    func start(jobID: UUID) async throws {}
    func step(jobID: UUID, _ update: StepUpdate) async throws {}
    func info(jobID: UUID, _ info: JobRunInfo) async throws {}
    func log(jobID: UUID, _ batch: LogBatch) async throws {}
    func uploadArtifact(jobID: UUID, name: String, fileURL: URL) async throws {}
    func finish(jobID: UUID, _ result: JobResult) async throws {}
}

/// Runs jobs by blocking until the test releases them; sees the cancel flag the loop hands it.
private final class BlockingJobRunner: JobRunning, Sendable {
    private struct State {
        var started: [UUID] = []
        var released: Set<UUID> = []
        var sawCancel: Set<UUID> = []
        var stopReasons: [UUID: String] = [:]
    }

    private let state = Mutex(State())
    /// When set, a job ends as soon as its cancel flag is raised.
    private let endsOnCancel: Bool

    init(endsOnCancel: Bool = false) { self.endsOnCancel = endsOnCancel }

    var started: [UUID] { state.withLock { $0.started } }
    var sawCancel: Set<UUID> { state.withLock { $0.sawCancel } }
    var stopReasons: [UUID: String] { state.withLock { $0.stopReasons } }

    func release(_ id: UUID) { state.withLock { _ = $0.released.insert(id) } }

    func run(
        _ assignment: JobAssignment, cancelled: @escaping @Sendable () -> Bool,
        stopReason: @escaping @Sendable () -> String?
    ) async -> JobResult {
        let id = assignment.job.id
        state.withLock { $0.started.append(id) }
        while true {
            if cancelled() {
                state.withLock {
                    $0.sawCancel.insert(id)
                    if let reason = stopReason() { $0.stopReasons[id] = reason }
                }
                if endsOnCancel { return JobResult(status: .cancelled) }
            }
            if state.withLock({ $0.released.contains(id) }) { return JobResult(status: .succeeded) }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// Records what the loop asks of the updater; never downloads or re-executes.
private final class FakeUpdater: WorkerUpdating {
    private let installs = Mutex<[String]>([])
    var installed: [String] { installs.withLock { $0 } }

    func download(from server: URL) async throws -> Data { Data("new worker".utf8) }
    func install(_ data: Data, sha256: String) throws { installs.withLock { $0.append(sha256) } }
}

@Suite(.timeLimit(.minutes(1))) struct WorkerLoopTests {
    static func assignment() -> JobAssignment {
        let job = Job(
            id: UUID(), buildID: UUID(), action: WorkflowAction(scheme: "Demo", platform: .iOS, export: .appStoreConnect),
            status: .assigned, createdAt: Date(timeIntervalSince1970: 0))
        return JobAssignment(
            job: job,
            app: App(
                id: UUID(), slug: "demo", name: "Demo", repoURL: "https://github.com/acme/demo.git",
                appStoreConnectAppID: "1234", createdAt: Date(timeIntervalSince1970: 0)),
            workflow: Workflow(project: "Demo.xcodeproj", xcode: "27.2", actions: [job.action]),
            workflowName: "release", buildNumber: 1, commit: String(repeating: "a", count: 40), ref: "main",
            environment: [])
    }

    /// A data directory that does not exist yet.
    static func dataDirectory() -> String { NSTemporaryDirectory() + "hangar-loop-" + UUID().uuidString }

    fileprivate static func loop(
        connection: some ServerConnection, runner: some JobRunning, clock: ManualClock, dataDirectory: String,
        maxConcurrentJobs: Int = 1, temporaryRoot: String? = nil, updater: FakeUpdater = FakeUpdater(),
        workDirectory: String? = nil
    ) -> WorkerLoop {
        let processes = DoctorTests.scriptedRunner()
        return WorkerLoop(
            configuration: WorkerConfiguration(
                serverURL: URL(string: "http://hangar.test")!, token: "t", maxConcurrentJobs: maxConcurrentJobs,
                dataDirectory: dataDirectory, workDirectory: workDirectory),
            connection: connection,
            doctor: DoctorTests.doctor(processes),
            jobRunner: runner, clock: clock,
            // Never the real per-user hangar-jobs: a live worker on this Mac keeps its jobs' TMPDIRs there.
            temporaryRoot: temporaryRoot ?? dataDirectory + "-tmp", updater: updater)
    }

    /// Polls (in real time, briefly) until `condition` holds; the suite's time limit bounds a condition that never does.
    static func eventually(_ condition: @Sendable () -> Bool) async {
        while !condition() { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// Lets the loops run a little, for asserting that something does *not* happen.
    static func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

    @Test func heartbeatsAndPicksUpOneJobAtATime() async throws {
        let first = Self.assignment()
        let second = Self.assignment()
        let connection = ScriptedConnection(answers: [.job(first), .job(second)])
        let runner = BlockingJobRunner()
        let clock = ManualClock()
        let directory = Self.dataDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let task = Task { await Self.loop(connection: connection, runner: runner, clock: clock, dataDirectory: directory).run() }

        await Self.eventually { runner.started == [first.job.id] && clock.sleeperCount == 1 }
        #expect(connection.heartbeats.count >= 1)
        await Self.settle()
        #expect(connection.nextJobCalls == 1, "the second job is not requested while the first runs")

        clock.advance(by: .seconds(30))
        await Self.eventually { connection.heartbeats.count >= 2 }
        #expect(connection.heartbeats.last?.report.runningJobIDs == [first.job.id])
        #expect(clock.requested.first == .seconds(30))

        runner.release(first.job.id)
        await Self.eventually { runner.started == [first.job.id, second.job.id] }
        await Self.settle()
        #expect(connection.nextJobCalls == 2, "nothing more is requested while the second job runs")

        runner.release(second.job.id)
        await Self.eventually { connection.nextJobCalls == 3 }
        task.cancel()
        await task.value
    }

    @Test func sweepsTheDiskOnStartAndAgainOnceTheServerSaysWhatJobsNeed() async throws {
        let directory = Self.dataDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let storage = VMStorage(root: directory + "/vm")
        for (name, xcode) in [("xcode-27.1", "27.1"), ("xcode-27.3", "27.3")] {
            let image = storage.image(name)
            try FileManager.default.createDirectory(atPath: image.path, withIntermediateDirectories: true)
            try VMBundleFile.write(
                TartConfig(cpuCountMin: 2, cpuCount: 4, memorySizeMin: 1, memorySize: 1, macAddress: "m", hardwareModel: "", ecid: ""),
                to: image.config)
            try VMBundleFile.write(
                VMImageMetadata(name: name, xcode: xcode, source: "t", createdAt: Date(), buildUser: "builder"), to: image.metadata)
        }
        let connection = ScriptedConnection(heartbeatResponses: [HeartbeatResponse(xcodesNeeded: ["27.3"])])
        let clock = ManualClock()
        let sweeper = DiskSweeper(
            locations: DiskSweeper.Locations(
                workDirectory: directory + "/work", dataDirectory: directory, systemTemporary: directory + "/T",
                vm: VMSettings(storage: storage.root)),
            workspaces: WorkspaceUse(),
            hostXcodes: { [InstalledXcode(version: "27.3", build: "", path: "/Applications/Xcode.app")] })
        let loop = WorkerLoop(
            configuration: WorkerConfiguration(
                serverURL: URL(string: "http://hangar.test")!, token: "t", dataDirectory: directory),
            connection: connection, doctor: DoctorTests.doctor(DoctorTests.scriptedRunner()), jobRunner: BlockingJobRunner(),
            clock: clock, temporaryRoot: directory + "-tmp", updater: FakeUpdater(), sweeper: sweeper)
        let task = Task { await loop.run() }
        await Self.eventually { sweeper.usage != nil && !connection.heartbeats.isEmpty }
        clock.advance(by: .seconds(30))
        await Self.eventually { !FileManager.default.fileExists(atPath: storage.image("xcode-27.1").path) }
        #expect(FileManager.default.fileExists(atPath: storage.image("xcode-27.3").path))
        task.cancel()
        await task.value
    }

    @Test func backsOffOnTransportErrors() async throws {
        let answers: [ScriptedConnection.Answer] =
            [.failure, .failure, .failure, .failure, .failure, .failure, .nothing, .failure]
        let connection = ScriptedConnection(answers: answers)
        let clock = ManualClock()
        let directory = Self.dataDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let task = Task {
            await Self.loop(connection: connection, runner: BlockingJobRunner(), clock: clock, dataDirectory: directory).run()
        }

        // The heartbeat loop sleeps 30 s between beats; every other sleep is the pull loop backing off.
        @Sendable func backoffs() -> [Duration] { clock.requested.filter { $0 != .seconds(30) } }
        let expected: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60), .seconds(5)]
        for (index, delay) in expected.enumerated() {
            await Self.eventually { backoffs().count > index }
            #expect(backoffs()[index] == delay)
            clock.advance(by: delay)
        }
        await Self.eventually { connection.nextJobCalls == 9 }
        task.cancel()
        await task.value
    }

    @Test func cancelFlagReachesRunningJob() async throws {
        let job = Self.assignment()
        let other = UUID()
        let connection = ScriptedConnection(
            answers: [.job(job)],
            heartbeatResponses: [HeartbeatResponse(), HeartbeatResponse(cancelJobIDs: [other, job.job.id])])
        let runner = BlockingJobRunner(endsOnCancel: true)
        let clock = ManualClock()
        let directory = Self.dataDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let task = Task { await Self.loop(connection: connection, runner: runner, clock: clock, dataDirectory: directory).run() }

        await Self.eventually { runner.started == [job.job.id] && clock.sleeperCount == 1 }
        await Self.settle()
        #expect(runner.sawCancel.isEmpty)

        clock.advance(by: .seconds(30))
        await Self.eventually { runner.sawCancel == [job.job.id] }
        task.cancel()
        await task.value
    }

    @Test func stopCancelsRunningJobsWithTheReasonAndReturns() async throws {
        let job = Self.assignment()
        let connection = ScriptedConnection(answers: [.job(job), .job(Self.assignment())])
        let runner = BlockingJobRunner(endsOnCancel: true)
        let clock = ManualClock()
        let directory = Self.dataDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let loop = Self.loop(connection: connection, runner: runner, clock: clock, dataDirectory: directory)
        let task = Task { await loop.run() }

        await Self.eventually { runner.started == [job.job.id] }
        await loop.stop(reason: "hangar-worker on mini was stopped (SIGTERM)")
        // run() returns on its own once the job has ended; nothing else is asked for.
        await task.value
        #expect(runner.stopReasons == [job.job.id: "hangar-worker on mini was stopped (SIGTERM)"])
        #expect(connection.nextJobCalls == 1)
        #expect(runner.started == [job.job.id])
    }

    @Test func stopCancelsTheLongPollAndLeavesAJobItBringsToTheNextRun() async throws {
        let job = Self.assignment()
        let connection = ScriptedConnection(answers: [.jobWhenCancelled(job)])
        let runner = BlockingJobRunner(endsOnCancel: true)
        let directory = Self.dataDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let loop = Self.loop(connection: connection, runner: runner, clock: ManualClock(), dataDirectory: directory)
        let task = Task { await loop.run() }

        await Self.eventually { connection.nextJobCalls == 1 }
        await loop.stop(reason: "stopped")
        await task.value
        #expect(runner.started.isEmpty)
    }

    @Test func updateDoesNotRestartWhileAPollBringsAJob() async throws {
        let job = Self.assignment()
        let update = HeartbeatResponse(workerUpdate: WorkerUpdate(sha256: String(repeating: "f", count: 64)))
        let connection = ScriptedConnection(answers: [.jobWhenCancelled(job)], heartbeatResponses: [update])
        let runner = BlockingJobRunner()
        let updater = FakeUpdater()
        let directory = Self.dataDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let loop = Self.loop(
            connection: connection, runner: runner, clock: ManualClock(), dataDirectory: directory, updater: updater)
        let task = Task { await loop.run() }

        // The update cancels the poll in flight, which still brings the job: the job runs and the update is dropped.
        await Self.eventually { runner.started == [job.job.id] }
        await Self.settle()
        #expect(updater.installed.isEmpty)
        runner.release(job.job.id)
        task.cancel()
        await task.value
    }

    @Test func updateInstallsOnceTheIdlePollIsCancelled() async throws {
        let sha = String(repeating: "e", count: 64)
        let connection = ScriptedConnection(heartbeatResponses: [HeartbeatResponse(workerUpdate: WorkerUpdate(sha256: sha))])
        let updater = FakeUpdater()
        let directory = Self.dataDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let loop = Self.loop(
            connection: connection, runner: BlockingJobRunner(), clock: ManualClock(), dataDirectory: directory,
            updater: updater)
        let task = Task { await loop.run() }

        await Self.eventually { updater.installed == [sha] }
        // The fake install returns (a real one re-executes); polling then resumes.
        await Self.eventually { connection.nextJobCalls == 2 }
        task.cancel()
        await task.value
    }

    @Test func sweepsJobDirectoriesLeftByACrashBeforeTheFirstHeartbeat() async throws {
        let directory = Self.dataDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let jobs = directory + "/jobs"
        let leftovers = [UUID().uuidString, UUID().uuidString].map { jobs + "/" + $0 }
        for leftover in leftovers {
            try FileManager.default.createDirectory(atPath: leftover + "/secrets", withIntermediateDirectories: true)
            try "secret".write(toFile: leftover + "/secrets/key.pem", atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(atPath: leftover + "/archive", withIntermediateDirectories: true)
        }
        // A cached workspace next to jobs/ is not a job directory.
        try FileManager.default.createDirectory(atPath: directory + "/workspaces/demo", withIntermediateDirectories: true)

        let connection = ScriptedConnection()
        let task = Task {
            await Self.loop(
                connection: connection, runner: BlockingJobRunner(), clock: ManualClock(), dataDirectory: directory
            ).run()
        }
        await Self.eventually { connection.heartbeats.count >= 1 }
        task.cancel()
        await task.value

        #expect(try FileManager.default.contentsOfDirectory(atPath: jobs).isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory + "/workspaces/demo"))
    }

    @Test func movesTheWorkspacesToTheWorkDirectoryAndSweepsBothJobFolders() async throws {
        let directory = Self.dataDirectory()
        let work = directory + "-work"
        defer {
            try? FileManager.default.removeItem(atPath: directory)
            try? FileManager.default.removeItem(atPath: work)
        }
        try FileManager.default.createDirectory(atPath: directory + "/workspaces/demo/DerivedData", withIntermediateDirectories: true)
        for jobs in [directory + "/jobs", work + "/jobs"] {
            try FileManager.default.createDirectory(atPath: jobs + "/" + UUID().uuidString, withIntermediateDirectories: true)
        }

        let connection = ScriptedConnection()
        let task = Task {
            await Self.loop(
                connection: connection, runner: BlockingJobRunner(), clock: ManualClock(), dataDirectory: directory,
                temporaryRoot: work + "/tmp", workDirectory: work
            ).run()
        }
        await Self.eventually { connection.heartbeats.count >= 1 }
        task.cancel()
        await task.value

        #expect(FileManager.default.fileExists(atPath: work + "/workspaces/demo/DerivedData"))
        #expect(!FileManager.default.fileExists(atPath: directory + "/workspaces"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory + "/jobs").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: work + "/jobs").isEmpty)
    }

    @Test func sweepsTemporaryDirectoriesLeftByACrash() async throws {
        let directory = Self.dataDirectory()
        let temporaryRoot = directory + "-tmp"
        defer {
            try? FileManager.default.removeItem(atPath: directory)
            try? FileManager.default.removeItem(atPath: temporaryRoot)
        }
        let leftover = temporaryRoot + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: leftover + "/nested", withIntermediateDirectories: true)
        try "x".write(toFile: leftover + "/nested/f", atomically: true, encoding: .utf8)

        let connection = ScriptedConnection()
        let task = Task {
            await Self.loop(
                connection: connection, runner: BlockingJobRunner(), clock: ManualClock(), dataDirectory: directory,
                temporaryRoot: temporaryRoot
            ).run()
        }
        await Self.eventually { connection.heartbeats.count >= 1 }
        task.cancel()
        await task.value

        #expect(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot).isEmpty)
    }

    @Test func createsAMissingDataDirectory() async throws {
        let directory = Self.dataDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let connection = ScriptedConnection()
        let task = Task {
            await Self.loop(
                connection: connection, runner: BlockingJobRunner(), clock: ManualClock(), dataDirectory: directory
            ).run()
        }
        await Self.eventually { connection.heartbeats.count >= 1 }
        task.cancel()
        await task.value
        #expect(FileManager.default.fileExists(atPath: directory))
    }
}
