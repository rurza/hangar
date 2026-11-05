import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

/// One-job tokens: what a job's VM holds instead of the machine token (VM builds design, *How the worker talks to the
/// guest*), and what it can and cannot do with one.
@Suite(.timeLimit(.minutes(1))) struct JobTokenTests {
    typealias Setup = WorkerAPITests.Setup
    static let t0 = WorkerAPITests.t0

    /// A token for `job`, asked for with the machine token.
    static func issue(_ job: Job, _ setup: Setup, client: some TestClientProtocol) async throws -> String {
        try await client.execute(uri: "/api/v1/worker/jobs/\(job.id.uuidString)/token", method: .post, headers: setup.auth) {
            response throws in
            #expect(response.status == .created)
            return try decode(JobTokenResponse.self, response).token
        }
    }

    static func expectStatus(
        _ client: some TestClientProtocol, _ method: HTTPRequest.Method, _ path: String, token: String,
        body: ByteBuffer? = nil, _ status: HTTPResponse.Status, code: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await client.execute(
            uri: "/api/v1/worker/\(path)", method: method, headers: WorkerAPITests.auth(token), body: body
        ) { response throws in
            #expect(response.status == status, "\(method) \(path)", sourceLocation: sourceLocation)
            if let code {
                #expect(try decode(APIError.self, response).code == code, "\(method) \(path)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func theTokenIsRandomPrefixedAndStoredOnlyAsAHash() async throws {
        let setup = try await Setup()
        let job = setup.build.jobs[0]
        try await setup.fixture.test { client in
            let first = try await Self.issue(job, setup, client: client)
            let second = try await Self.issue(job, setup, client: client)
            #expect(first.hasPrefix("hgj_"))
            #expect(first.count == 4 + 43)
            #expect(first != second)
            #expect(first != setup.token)
        }
        let server = setup.fixture.server
        #expect(try server.jobTokens.count(jobID: job.id) == 2)
        let stored = try server.database.read { db in try String.fetchAll(db, sql: "SELECT token_hash FROM job_tokens") }
        #expect(stored.allSatisfy { $0.count == 64 && !$0.hasPrefix("hgj_") })
    }

    @Test func aJobTokenRunsItsOwnJobFromStartToFinish() async throws {
        let setup = try await Setup()
        let job = setup.build.jobs[0]
        let id = job.id.uuidString
        try await setup.fixture.test { client in
            let token = try await Self.issue(job, setup, client: client)
            try await Self.expectStatus(client, .post, "jobs/\(id)/start", token: token, .ok)
            try await Self.expectStatus(
                client, .post, "jobs/\(id)/info", token: token, body: try body(JobRunInfo(workerVersion: "0.11.0")), .ok)
            try await Self.expectStatus(
                client, .post, "jobs/\(id)/steps", token: token,
                body: try body(StepUpdate(name: StepName.checkout, status: .succeeded, at: Self.t0)), .ok)
            try await Self.expectStatus(
                client, .post, "jobs/\(id)/log", token: token,
                body: try body(LogBatch(entries: [LogEntry(t: Self.t0, step: "checkout", line: "Cloning")])), .noContent)
            try await Self.expectStatus(
                client, .post, "jobs/\(id)/artifacts/Legilo.ipa", token: token, body: ByteBuffer(string: "ipa"), .created)
            try await Self.expectStatus(
                client, .post, "jobs/\(id)/finish", token: token, body: try body(JobResult(status: .succeeded)), .ok)
            // Finished: the token is gone, and it says so before it says anything about the route.
            try await Self.expectStatus(client, .post, "jobs/\(id)/log", token: token,
                body: try body(LogBatch(entries: [LogEntry(t: Self.t0, step: "x", line: "late")])), .unauthorized,
                code: "invalid_job_token")
        }
        let server = setup.fixture.server
        #expect(try server.jobTokens.count(jobID: job.id) == 0)
        #expect(try server.builds.job(id: job.id)?.status == .succeeded)
        // Started by the token's machine, under its name.
        #expect(try server.builds.job(id: job.id)?.runInfo?.machineName == "studio")
    }

    @Test func aJobTokenCannotCallAnythingElse() async throws {
        let setup = try await Setup()
        let job = setup.build.jobs[0]
        let other = setup.build.jobs[1]
        let id = job.id.uuidString
        let otherID = other.id.uuidString
        let heartbeat = try body(HeartbeatRequest(report: WorkerAPITests.report()))
        try await setup.fixture.test { client in
            let token = try await Self.issue(job, setup, client: client)
            // The machine's own routes.
            try await Self.expectStatus(client, .post, "heartbeat", token: token, body: heartbeat, .forbidden, code: "job_token_scope")
            try await Self.expectStatus(client, .get, "jobs/next?wait=0", token: token, .forbidden, code: "job_token_scope")
            try await Self.expectStatus(client, .get, "me", token: token, .forbidden, code: "job_token_scope")
            // A token cannot mint or revoke tokens, not even for its own job.
            try await Self.expectStatus(client, .post, "jobs/\(id)/token", token: token, .forbidden, code: "job_token_scope")
            try await Self.expectStatus(client, .delete, "jobs/\(id)/token", token: token, .forbidden, code: "job_token_scope")
            // Another job on the same machine, on every route the token has for its own.
            for route in ["start", "info", "steps", "log", "finish", "artifacts/x.zip", "token"] {
                try await Self.expectStatus(
                    client, .post, "jobs/\(otherID)/\(route)", token: token, body: ByteBuffer(string: "{}"), .forbidden,
                    code: "job_token_scope")
            }
            // Its own routes under another shape. (By another method, e.g. GET start, they match no route at all.)
            try await Self.expectStatus(client, .post, "jobs/\(id)/start/", token: token, .forbidden, code: "job_token_scope")
            try await Self.expectStatus(client, .post, "jobs/\(id.lowercased())x/start", token: token, .forbidden, code: "job_token_scope")
        }
        let server = setup.fixture.server
        #expect(try server.builds.job(id: other.id)?.status == .assigned)
        #expect(try server.builds.job(id: job.id)?.status == .assigned)
        #expect(try server.jobTokens.count(jobID: job.id) == 1)
    }

    @Test func onlyAnActiveJobOfThisMachineGetsAToken() async throws {
        let setup = try await Setup()
        let server = setup.fixture.server
        let (_, laptopToken) = try server.machines.create(name: "laptop")
        let job = setup.build.jobs[0]
        let path = "jobs/\(job.id.uuidString)/token"
        try await setup.fixture.test { client in
            try await Self.expectStatus(client, .post, path, token: laptopToken, .conflict, code: "job_not_assigned_to_machine")
            try await Self.expectStatus(client, .post, "jobs/\(UUID().uuidString)/token", token: setup.token, .notFound, code: "job_not_found")
            try await Self.expectStatus(client, .post, path, token: "hgj_unknown", .unauthorized, code: "invalid_job_token")
            try server.builds.setJobStatus(id: job.id, status: .cancelled, at: Self.t0)
            try await Self.expectStatus(client, .post, path, token: setup.token, .conflict, code: "job_state_conflict")
        }
        #expect(try server.jobTokens.count(jobID: job.id) == 0)
    }

    @Test func aTokenExpiresWhenItsJobEndsOrMovesWithoutBeingRevoked() async throws {
        let setup = try await Setup()
        let server = setup.fixture.server
        let (laptop, _) = try server.machines.create(name: "laptop")
        let cancelled = setup.build.jobs[0]
        let moved = setup.build.jobs[1]
        try await setup.fixture.test { client in
            let cancelledToken = try await Self.issue(cancelled, setup, client: client)
            let movedToken = try await Self.issue(moved, setup, client: client)
            try await Self.expectStatus(client, .post, "jobs/\(cancelled.id.uuidString)/start", token: cancelledToken, .ok)

            // Cancelled by its user (or failed as lost): terminal, whatever the worker does.
            try server.builds.setJobStatus(id: cancelled.id, status: .cancelled, at: Self.t0)
            try await Self.expectStatus(
                client, .post, "jobs/\(cancelled.id.uuidString)/finish", token: cancelledToken,
                body: try body(JobResult(status: .failed)), .unauthorized, code: "invalid_job_token")

            // Requeued, then given to another machine: the first machine's token no longer works for it.
            #expect(try server.builds.unassign(jobID: moved.id))
            try await Self.expectStatus(
                client, .post, "jobs/\(moved.id.uuidString)/start", token: movedToken, .unauthorized, code: "invalid_job_token")
            #expect(try server.builds.assign(jobID: moved.id, to: laptop.id, at: Self.t0))
            try await Self.expectStatus(
                client, .post, "jobs/\(moved.id.uuidString)/start", token: movedToken, .unauthorized, code: "invalid_job_token")
        }
        #expect(try server.builds.job(id: moved.id)?.status == .assigned)
    }

    @Test func deleteRevokesTheMachinesTokensForTheJob() async throws {
        let setup = try await Setup()
        let server = setup.fixture.server
        let job = setup.build.jobs[0]
        let other = setup.build.jobs[1]
        let path = "jobs/\(job.id.uuidString)/token"
        try await setup.fixture.test { client in
            let token = try await Self.issue(job, setup, client: client)
            let second = try await Self.issue(job, setup, client: client)
            let otherToken = try await Self.issue(other, setup, client: client)
            try await Self.expectStatus(client, .delete, path, token: setup.token, .noContent)
            for revoked in [token, second] {
                try await Self.expectStatus(
                    client, .post, "jobs/\(job.id.uuidString)/start", token: revoked, .unauthorized, code: "invalid_job_token")
            }
            // Idempotent, and the machine's other job keeps its token.
            try await Self.expectStatus(client, .delete, path, token: setup.token, .noContent)
            try await Self.expectStatus(client, .post, "jobs/\(other.id.uuidString)/start", token: otherToken, .ok)
            // The machine token still works for the job itself.
            try await Self.expectStatus(client, .post, "jobs/\(job.id.uuidString)/start", token: setup.token, .ok)
        }
        #expect(try server.jobTokens.count(jobID: job.id) == 0)
        #expect(try server.jobTokens.count(jobID: other.id) == 1)
    }

    @Test func removingTheMachineRemovesItsTokens() async throws {
        let setup = try await Setup()
        let server = setup.fixture.server
        let job = setup.build.jobs[0]
        _ = try server.jobTokens.issue(jobID: job.id, machineID: setup.machine.id)
        try server.machines.delete(id: setup.machine.id)
        #expect(try server.jobTokens.count(jobID: job.id) == 0)
    }

    @Test func thePolicyAllowsOnlyTheJobsOwnReportingRoutes() {
        let id = UUID()
        let job = "jobs/\(id.uuidString)"
        for path in ["start", "info", "steps", "log", "finish", "artifacts/Legilo.xcarchive.zip"] {
            #expect(JobTokenPolicy.allows(method: .post, path: "\(job)/\(path)", jobID: id), "\(path)")
        }
        #expect(JobTokenPolicy.allows(method: .post, path: "jobs/\(id.uuidString.lowercased())/start", jobID: id))
        let refused: [(HTTPRequest.Method, String)] = [
            (.get, "\(job)/start"), (.put, "\(job)/log"), (.delete, "\(job)/token"), (.post, "\(job)/token"),
            (.post, "\(job)/artifacts"), (.post, "\(job)/artifacts/"), (.post, "\(job)/artifacts/a/b"),
            (.post, "\(job)/start/"), (.post, "\(job)"), (.post, "jobs/\(UUID().uuidString)/start"),
            (.post, "heartbeat"), (.get, "jobs/next"), (.get, "me"), (.post, "jobs//start"), (.post, ""),
        ]
        for (method, path) in refused {
            #expect(!JobTokenPolicy.allows(method: method, path: path, jobID: id), "\(method) \(path)")
        }
    }
}
