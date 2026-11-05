import Clocks
import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing

@testable import HangarServer

/// A wall clock the test moves by hand.
final class ManualNow: Sendable {
    private let date: Mutex<Date>
    init(_ date: Date) { self.date = Mutex(date) }
    func callAsFunction() -> Date { date.withLock { $0 } }
    func advance(by seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

/// The routes worker machines call, under `/api/v1/worker`.
@Suite(.timeLimit(.minutes(1))) struct WorkerAPITests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func report(running: [UUID] = []) -> MachineReport {
        MachineReport(
            macOSVersion: "26.1", xcodes: [InstalledXcode(version: "27.2", build: "27C5", path: "/Applications/Xcode.app")],
            chip: "Apple M4 Pro", performanceCores: 10, memoryGB: 64, freeDiskGB: 400, onACPower: true,
            tools: ["brew": "4.6.0"], canSignWithoutPrompt: true, runningJobIDs: running)
    }

    static func auth(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)"] }

    /// A deployed two-job build whose jobs are both assigned to the machine `studio`.
    struct Setup {
        let fixture: APIFixture
        let machine: Machine
        let token: String
        let build: Build

        init(
            clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { WorkerAPITests.t0 },
            assign: Bool = true, workflow: String = "testflight", workerBinaryPath: String? = nil
        ) async throws {
            fixture = try APIFixture(clock: clock, now: now, workerBinaryPath: workerBinaryPath)
            try fixture.createApp()
            (machine, token) = try fixture.server.machines.create(name: "studio")
            build = try await fixture.server.buildService.deploy(DeployRequest(app: "legilo", workflow: workflow, ref: "main"))
            if assign {
                for job in build.jobs { #expect(try fixture.server.builds.assign(jobID: job.id, to: machine.id, at: WorkerAPITests.t0)) }
            }
        }

        var auth: HTTPFields { WorkerAPITests.auth(token) }
    }

    @Test func rejectsMissingOrWrongToken() async throws {
        let setup = try await Setup()
        let heartbeat = try body(HeartbeatRequest(report: Self.report()))
        try await setup.fixture.test { client in
            let attempts: [HTTPFields] = [[:], Self.auth("wrong"), [.authorization: "Basic \(setup.token)"], Self.auth("")]
            for headers in attempts {
                try await client.execute(uri: "/api/v1/worker/heartbeat", method: .post, headers: headers, body: heartbeat) {
                    response throws in
                    #expect(response.status == .unauthorized)
                    #expect(try decode(APIError.self, response).code == "unauthorized")
                }
                try await client.execute(uri: "/api/v1/worker/jobs/next?wait=0", method: .get, headers: headers) { response in
                    #expect(response.status == .unauthorized)
                }
            }
            try await client.execute(uri: "/api/v1/worker/heartbeat", method: .post, headers: setup.auth, body: heartbeat) { response in
                #expect(response.status == .ok)
            }
            // The public API needs no machine token.
            try await client.execute(uri: "/api/v1/builds/\(setup.build.id.uuidString)", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }

    /// An archive job's assignment leaves out the workflow's test actions, so a worker from before test actions can
    /// still decode it; a test job's carries the whole workflow.
    @Test func archiveAssignmentsOfAMixedWorkflowCarryOnlyArchiveActions() async throws {
        let setup = try await Setup(workflow: "ci")
        let archive = try #require(setup.build.jobs.first { $0.action.kind == .archive })
        let test = try #require(setup.build.jobs.first { $0.action.kind == .test })
        let server = setup.fixture.server
        try await setup.fixture.test { client in
            var seen: [ActionKind: JobAssignment] = [:]
            for _ in 0..<2 {
                let assignment = try await client.execute(uri: "/api/v1/worker/jobs/next?wait=0", method: .get, headers: setup.auth) {
                    try decode(JobAssignment.self, $0)
                }
                seen[assignment.job.action.kind] = assignment
                try server.builds.setJobStatus(id: assignment.job.id, status: .cancelled, at: WorkerAPITests.t0)
            }
            #expect(seen[.archive]?.job.id == archive.id)
            #expect(seen[.archive]?.workflow.actions == [archive.action])
            #expect(seen[.test]?.job.id == test.id)
            #expect(seen[.test]?.workflow.actions.count == 2)
        }
    }

    @Test func nextReturns204WhenNothingAssigned() async throws {
        let setup = try await Setup(assign: false)
        try await setup.fixture.test { client in
            try await client.execute(uri: "/api/v1/worker/jobs/next?wait=0", method: .get, headers: setup.auth) { response in
                #expect(response.status == .noContent)
                #expect(response.body.readableBytes == 0)
            }
        }
    }

    @Test func nextReturnsAssignmentWithResolvedSecrets() async throws {
        let setup = try await Setup()
        let server = setup.fixture.server
        let app = try #require(try server.apps.find(slugOrID: "legilo"))
        try server.variables.set(scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "ghp-global", isSecret: true))
        try server.variables.set(scope: .app(app.id), name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "ghp-app", isSecret: true))
        try server.variables.set(scope: .global, name: "TEAM", input: VariableInput(value: "YL78V8PY6H"))
        let (_, otherToken) = try server.machines.create(name: "laptop")
        try await setup.fixture.test { client in
            let assignment = try await client.execute(uri: "/api/v1/worker/jobs/next?wait=0", method: .get, headers: setup.auth) {
                #expect($0.status == .ok)
                return try decode(JobAssignment.self, $0)
            }
            #expect(setup.build.jobs.map(\.id).contains(assignment.job.id))
            #expect(assignment.job.status == .assigned)
            #expect(assignment.job.machineID == setup.machine.id)
            // Compared by ID: a date's ISO 8601 round trip need not give back the identical Double.
            #expect(assignment.app.id == app.id)
            #expect(assignment.workflow == (try server.builds.workflow(buildID: setup.build.id)))
            #expect(assignment.workflowName == "testflight")
            #expect(assignment.buildNumber == setup.build.buildNumber)
            #expect(assignment.commit == setup.build.commit)
            #expect(assignment.ref == "main")
            #expect(
                assignment.environment == [
                    EnvEntry(name: "HANGAR_GITHUB_TOKEN", value: "ghp-app", isSecret: true),
                    EnvEntry(name: "TEAM", value: "YL78V8PY6H"),
                ])
            // Another machine gets nothing: the secrets go only to the machine the job is assigned to.
            try await client.execute(uri: "/api/v1/worker/jobs/next?wait=0", method: .get, headers: Self.auth(otherToken)) {
                response in
                #expect(response.status == .noContent)
                #expect(!String(buffer: response.body).contains("ghp-app"))
            }
        }
    }

    @Test func nextLongPollWakesOnAssignmentAndTimesOutOnTheClock() async throws {
        let clock = TestClock()
        let setup = try await Setup(clock: clock, assign: false)
        let server = setup.fixture.server
        let job = setup.build.jobs[0]
        try await setup.fixture.test { client in
            async let woken = client.execute(uri: "/api/v1/worker/jobs/next?wait=60", method: .get, headers: setup.auth) { $0 }
            try await setup.fixture.waitForSubscriber()
            // What the scheduler does: assign, then publish the job.
            #expect(try server.builds.assign(jobID: job.id, to: setup.machine.id, at: Self.t0))
            server.events.publish(.server(.job(try #require(try server.builds.job(id: job.id)))))
            let response = try await woken
            #expect(response.status == .ok)
            #expect(try decode(JobAssignment.self, response).job.id == job.id)

            // Nothing for this machine: answered with 204 once the injected clock passes the deadline.
            let (_, otherToken) = try server.machines.create(name: "laptop")
            let status = try await withThrowingTaskGroup(of: HTTPResponse.Status?.self) { group in
                group.addTask {
                    try await client.execute(uri: "/api/v1/worker/jobs/next?wait=5", method: .get, headers: Self.auth(otherToken)) {
                        $0.status
                    }
                }
                group.addTask {
                    // The handler may start sleeping after any one advance; keep advancing until it answers.
                    while !Task.isCancelled {
                        await clock.advance(by: .seconds(1))
                        try? await Task.sleep(for: .milliseconds(2))
                    }
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            #expect(status == .noContent)
        }
    }

    @Test func anotherMachineCannotStartTheJob() async throws {
        let setup = try await Setup()
        let (_, otherToken) = try setup.fixture.server.machines.create(name: "laptop")
        let job = setup.build.jobs[0]
        let other = Self.auth(otherToken)
        try await setup.fixture.test { client in
            try await client.execute(uri: "/api/v1/worker/jobs/\(job.id.uuidString)/start", method: .post, headers: other) {
                response throws in
                #expect(response.status == .conflict)
                #expect(try decode(APIError.self, response).code == "job_not_assigned_to_machine")
            }
            let log = try body(LogBatch(entries: [LogEntry(t: Self.t0, step: "checkout", line: "x")]))
            try await client.execute(uri: "/api/v1/worker/jobs/\(job.id.uuidString)/log", method: .post, headers: other, body: log) {
                response in
                #expect(response.status == .conflict)
            }
            try await client.execute(
                uri: "/api/v1/worker/jobs/\(job.id.uuidString)/finish", method: .post, headers: other,
                body: try body(JobResult(status: .failed))
            ) { response in #expect(response.status == .conflict) }
            try await client.execute(uri: "/api/v1/worker/jobs/\(UUID().uuidString)/start", method: .post, headers: other) {
                response throws in
                #expect(response.status == .notFound)
                #expect(try decode(APIError.self, response).code == "job_not_found")
            }
            #expect(try setup.fixture.server.builds.job(id: job.id)?.status == .assigned)

            // The owner can start it once.
            try await client.execute(uri: "/api/v1/worker/jobs/\(job.id.uuidString)/start", method: .post, headers: setup.auth) {
                response throws in
                #expect(response.status == .ok)
                #expect(try decode(Job.self, response).status == .running)
            }
            try await client.execute(uri: "/api/v1/worker/jobs/\(job.id.uuidString)/start", method: .post, headers: setup.auth) {
                response throws in
                #expect(response.status == .conflict)
                #expect(try decode(APIError.self, response).code == "job_state_conflict")
            }
        }
    }

    @Test func lifecycleStartStepsLogFinishUpdatesBuild() async throws {
        let setup = try await Setup()
        let server = setup.fixture.server
        let updates = server.events.subscribe()
        // Larger than Hummingbird's default 2 MB upload limit: the body is streamed, never collected.
        let archive = ByteBuffer(repeating: 0x5A, count: 3 * 1024 * 1024)
        try await setup.fixture.test { client in
            for job in setup.build.jobs {
                let path = "/api/v1/worker/jobs/\(job.id.uuidString)"
                // Steps, logs and artifacts are refused until the job runs.
                try await client.execute(
                    uri: "\(path)/steps", method: .post, headers: setup.auth,
                    body: try body(StepUpdate(name: StepName.checkout, status: .running, at: Self.t0))
                ) { response in #expect(response.status == .conflict) }

                try await client.execute(uri: "\(path)/start", method: .post, headers: setup.auth) { response in
                    #expect(response.status == .ok)
                }
                try await client.execute(
                    uri: "\(path)/steps", method: .post, headers: setup.auth,
                    body: try body(StepUpdate(name: StepName.checkout, status: .succeeded, at: Self.t0))
                ) { response throws in
                    #expect(response.status == .ok)
                    #expect(try decode(Job.self, response).steps == [StepRecord(name: "checkout", status: .succeeded, finishedAt: Self.t0)])
                }
                let entries = [LogEntry(t: Self.t0, step: "checkout", line: "Cloning \(job.action.scheme)")]
                try await client.execute(
                    uri: "\(path)/log", method: .post, headers: setup.auth, body: try body(LogBatch(entries: entries))
                ) { response in #expect(response.status == .noContent) }
                #expect(try await server.logStore.read(jobID: job.id, step: nil, tail: nil) == entries)

                try await client.execute(uri: "\(path)/artifacts/Legilo.xcarchive.zip", method: .post, headers: setup.auth, body: archive) {
                    response throws in
                    #expect(response.status == .created)
                    #expect(try decode(ArtifactInfo.self, response) == ArtifactInfo(name: "Legilo.xcarchive.zip", sizeBytes: archive.readableBytes))
                }
                try await client.execute(uri: "\(path)/artifacts/..", method: .post, headers: setup.auth, body: archive) { response in
                    #expect(response.status == .badRequest)
                }

                try await client.execute(
                    uri: "\(path)/finish", method: .post, headers: setup.auth, body: try body(JobResult(status: .running))
                ) { response throws in
                    #expect(response.status == .badRequest)
                    #expect(try decode(APIError.self, response).code == "invalid_job_result")
                }
                try await client.execute(
                    uri: "\(path)/finish", method: .post, headers: setup.auth,
                    body: try body(JobResult(status: .succeeded, outputs: ["testflight.buildID": "abc"]))
                ) { response throws in
                    #expect(response.status == .ok)
                    let finished = try decode(Job.self, response)
                    #expect(finished.status == .succeeded)
                    #expect(finished.startedAt == Self.t0)
                    #expect(finished.finishedAt == Self.t0)
                    #expect(finished.outputs == ["testflight.buildID": "abc"])
                }
                // A finished job takes no more finishes or uploads.
                try await client.execute(
                    uri: "\(path)/finish", method: .post, headers: setup.auth, body: try body(JobResult(status: .failed))
                ) { response throws in
                    #expect(response.status == .conflict)
                    #expect(try decode(APIError.self, response).code == "job_state_conflict")
                }
                try await client.execute(uri: "\(path)/artifacts/late.zip", method: .post, headers: setup.auth, body: archive) { response in
                    #expect(response.status == .conflict)
                }
            }

            try await client.execute(uri: "/api/v1/builds/\(setup.build.id.uuidString)", method: .get) { response throws in
                let build = try decode(Build.self, response)
                #expect(build.status == .succeeded)
                #expect(build.finishedAt != nil)
            }
            let job = setup.build.jobs[0]
            try await client.execute(uri: "/api/v1/jobs/\(job.id.uuidString)/artifacts", method: .get) { response throws in
                #expect(try decode([ArtifactInfo].self, response) == [ArtifactInfo(name: "Legilo.xcarchive.zip", sizeBytes: archive.readableBytes)])
            }
        }

        // Every change was published: the log batch, the jobs, and the build reaching `succeeded`.
        var logs = 0
        var succeededBuild = false
        for await event in updates {
            switch event {
            case .log: logs += 1
            case .server(.build(let build)) where build.status == .succeeded: succeededBuild = true
            default: break
            }
            if logs == 2 && succeededBuild { break }
        }
        #expect(logs == 2)
    }

    @Test func heartbeatReturnsCancelRequests() async throws {
        let setup = try await Setup()
        let server = setup.fixture.server
        let (running, assigned) = (setup.build.jobs[0], setup.build.jobs[1])
        let (_, otherToken) = try server.machines.create(name: "laptop")
        try await setup.fixture.test { client in
            try await client.execute(uri: "/api/v1/worker/jobs/\(running.id.uuidString)/start", method: .post, headers: setup.auth) {
                response in
                #expect(response.status == .ok)
            }
            func heartbeat(_ headers: HTTPFields, running: [UUID]) async throws -> [UUID] {
                try await client.execute(
                    uri: "/api/v1/worker/heartbeat", method: .post, headers: headers,
                    body: try body(HeartbeatRequest(report: Self.report(running: running)))
                ) {
                    #expect($0.status == .ok)
                    return try decode(HeartbeatResponse.self, $0).cancelJobIDs
                }
            }
            #expect(try await heartbeat(setup.auth, running: [running.id]) == [])
            let machine = try #require(try server.machines.find(nameOrID: "studio"))
            #expect(machine.lastSeenAt == Self.t0)
            #expect(machine.report == Self.report(running: [running.id]))

            _ = try await server.buildService.cancel(buildID: setup.build.id)
            // The running job is to stop; the assigned one, not started yet, was cancelled outright.
            #expect(try server.builds.job(id: assigned.id)?.status == .cancelled)
            #expect(try await heartbeat(setup.auth, running: [running.id]) == [running.id])
            // A worker that had already picked up the assigned job is told to drop it.
            #expect(Set(try await heartbeat(setup.auth, running: [running.id, assigned.id])) == [running.id, assigned.id])
            #expect(try await heartbeat(Self.auth(otherToken), running: []) == [])

            // Once the worker reports the job cancelled, its cancel request is cleared; a worker that still lists the
            // finished job is told to stop it because it is terminal on the server.
            try await client.execute(
                uri: "/api/v1/worker/jobs/\(running.id.uuidString)/finish", method: .post, headers: setup.auth,
                body: try body(JobResult(status: .cancelled))
            ) { response in #expect(response.status == .ok) }
            #expect(try await heartbeat(setup.auth, running: []) == [])
            #expect(try await heartbeat(setup.auth, running: [running.id]) == [running.id])
        }
    }

    func heartbeat(_ client: some TestClientProtocol, _ headers: HTTPFields, running: [UUID]) async throws -> [UUID] {
        try await client.execute(
            uri: "/api/v1/worker/heartbeat", method: .post, headers: headers,
            body: try body(HeartbeatRequest(report: Self.report(running: running)))
        ) {
            #expect($0.status == .ok)
            return try decode(HeartbeatResponse.self, $0).cancelJobIDs
        }
    }

    /// A worker that reports its binary's hash is told to replace it only when the server has a different one.
    /// A worker that reports no hash is left alone: it cannot apply the update.
    @Test func heartbeatOffersAWorkerUpdateOnlyWhenTheBinaryDiffers() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-worker-\(UUID().uuidString)")
        try Data("hangar-worker-bytes".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let current = try #require(SHA256File.hex(of: url))
        let setup = try await Setup(assign: false, workerBinaryPath: url.path)
        try await setup.fixture.test { client in
            func beat(_ hash: String?) async throws -> HeartbeatResponse {
                var report = WorkerAPITests.report()
                report.binarySHA256 = hash
                return try await client.execute(
                    uri: "/api/v1/worker/heartbeat", method: .post, headers: setup.auth,
                    body: try body(HeartbeatRequest(report: report))
                ) { response in
                    #expect(response.status == .ok)
                    return try decode(HeartbeatResponse.self, response)
                }
            }
            #expect(try await beat(nil).workerUpdate == nil)
            #expect(try await beat(current).workerUpdate == nil)
            let offered = try await beat(String(repeating: "ab", count: 32)).workerUpdate
            #expect(offered == WorkerUpdate(sha256: current))
        }
    }

    @Test func workerRestartedMidJobFailsTheJobAndFreesTheSlot() async throws {
        let now = ManualNow(Self.t0)
        let setup = try await Setup(now: { now() }, assign: false)
        let server = setup.fixture.server
        let (first, second) = (setup.build.jobs[0], setup.build.jobs[1])
        #expect(try server.builds.assign(jobID: first.id, to: setup.machine.id, at: Self.t0))
        try await setup.fixture.test { client in
            try await client.execute(uri: "/api/v1/worker/jobs/\(first.id.uuidString)/start", method: .post, headers: setup.auth) {
                response in
                #expect(response.status == .ok)
            }
            // The worker restarts: its next heartbeats no longer list the job. Within the grace nothing happens,
            // since a heartbeat may have been taken just before the job started.
            now.advance(by: 30)
            #expect(try await heartbeat(client, setup.auth, running: []) == [])
            #expect(try server.builds.job(id: first.id)?.status == .running)
            try await server.scheduler.tick()
            #expect(try server.builds.job(id: second.id)?.status == .queued)

            now.advance(by: 31)
            #expect(try await heartbeat(client, setup.auth, running: []) == [])
            let failed = try #require(try server.builds.job(id: first.id))
            #expect(failed.status == .failed)
            #expect(failed.failureReason == "worker lost track of the job")
            #expect(failed.finishedAt == now())
            #expect(try server.builds.build(id: setup.build.id)?.jobs.first { $0.id == first.id }?.status == .failed)

            // The machine's only slot is free again: the next job is assigned to it.
            try await server.scheduler.tick()
            let next = try #require(try server.builds.job(id: second.id))
            #expect(next.status == .assigned)
            #expect(next.machineID == setup.machine.id)

            // A job the heartbeat still lists keeps running however long it takes.
            try await client.execute(uri: "/api/v1/worker/jobs/\(second.id.uuidString)/start", method: .post, headers: setup.auth) {
                response in
                #expect(response.status == .ok)
            }
            now.advance(by: 3600)
            #expect(try await heartbeat(client, setup.auth, running: [second.id]) == [])
            #expect(try server.builds.job(id: second.id)?.status == .running)
        }
    }

    @Test func heartbeatAsksToStopJobsTheServerNoLongerRunsOnTheMachine() async throws {
        let setup = try await Setup()
        let server = setup.fixture.server
        let (finished, other) = (setup.build.jobs[0], setup.build.jobs[1])
        try await setup.fixture.test { client in
            for job in [finished, other] {
                try await client.execute(uri: "/api/v1/worker/jobs/\(job.id.uuidString)/start", method: .post, headers: setup.auth) {
                    response in
                    #expect(response.status == .ok)
                }
            }
            // Failed on the server (e.g. as lost) while the worker still runs it.
            #expect(try server.builds.transitionJob(id: finished.id, from: [.running], to: .failed, at: Self.t0))
            // A job the server has on another machine, and one it does not know.
            let (laptop, _) = try server.machines.create(name: "laptop")
            try server.builds.inTransaction { db in
                try db.execute(sql: "UPDATE jobs SET machine_id = ? WHERE id = ?", arguments: [laptop.id.uuidString, other.id.uuidString])
            }
            let unknown = UUID()
            let cancel = try await heartbeat(client, setup.auth, running: [finished.id, other.id, unknown])
            #expect(Set(cancel) == [finished.id, other.id, unknown])
            // The job stays failed, the other machine's job untouched.
            #expect(try server.builds.job(id: finished.id)?.status == .failed)
            #expect(try server.builds.job(id: other.id)?.status == .running)
        }
    }
}
