import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarClient

@Suite(.timeLimit(.minutes(1))) struct HangarAPITests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let base = URL(string: "http://mini.tailnet:8787")!

    static func build(status: BuildStatus = .queued) -> Build {
        let buildID = UUID()
        let job = Job(
            id: UUID(), buildID: buildID, action: WorkflowAction(scheme: "Legilo", platform: .iOS, export: .appStoreConnect),
            status: .queued, createdAt: t0)
        return Build(
            id: buildID, appID: UUID(), workflow: "testflight", ref: "main", commit: "abc1234", buildNumber: 42,
            status: status, createdAt: t0, jobs: [job])
    }

    static func json(_ value: some Encodable, status: Int = 200) throws -> StubTransport.Response {
        StubTransport.Response(status: status, body: try JSONCoding.encoder.encode(value))
    }

    /// An `openLines` seam that serves `text` as the stream's lines, recording the requests it was asked for.
    static func lines(_ text: String, recorder: Recorder = Recorder()) -> HangarAPI.LineStreamOpener {
        { request in
            recorder.record(request)
            return AsyncThrowingStream { continuation in
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) { continuation.yield(String(line)) }
                continuation.finish()
            }
        }
    }

    final class Recorder: Sendable {
        private let storage = Mutex<[URLRequest]>([])
        func record(_ request: URLRequest) { storage.withLock { $0.append(request) } }
        var requests: [URLRequest] { storage.withLock { $0 } }
    }

    @Test func sendsTheAPITokenOnEveryRequestAndStream() async throws {
        let token = "hgr_" + String(repeating: "x", count: 43)
        let transport = StubTransport(responses: [try Self.json([App]())])
        let recorder = Recorder()
        let api = HangarAPI(baseURL: Self.base, transport: transport, token: token, openLines: Self.lines("", recorder: recorder))
        _ = try await api.apps()
        _ = try? await api.followLog(jobID: UUID()).reduce(into: 0) { _, _ in }
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(recorder.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        let plain = StubTransport(responses: [try Self.json([App]())])
        _ = try await HangarAPI(baseURL: Self.base, transport: plain).apps()
        #expect(plain.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func deployCheckAndInspectPaths() async throws {
        let check = DeployCheck(canDeploy: true, blocking: [], warnings: [], machines: [])
        let inspection = RepositoryInspection(commit: "abc", apps: [], projects: [], notes: [])
        let transport = StubTransport(responses: [try Self.json(check), try Self.json(inspection)])
        let api = HangarAPI(baseURL: Self.base, transport: transport)
        _ = try await api.deployCheck(app: "legilo", workflow: "release", ref: "main")
        _ = try await api.inspectRepository("acme/legilo")
        #expect(transport.requests.map { $0.url?.absoluteString } == [
            "http://mini.tailnet:8787/api/v1/apps/legilo/deploy-check?workflow=release&ref=main",
            "http://mini.tailnet:8787/api/v1/github/repos/acme/legilo/inspect",
        ])
    }

    @Test func decodesAPIErrorIntoTypedError() async throws {
        let transport = StubTransport(responses: [
            try Self.json(APIError(code: "app_not_found", message: "No app 'nope'"), status: 404),
        ])
        let api = HangarAPI(baseURL: Self.base, transport: transport)
        let error = await #expect(throws: HangarAPIError.self) { try await api.app("nope") }
        guard case .server(let apiError, let status) = error else { Issue.record("expected .server, got \(String(describing: error))"); return }
        #expect(apiError == APIError(code: "app_not_found", message: "No app 'nope'"))
        #expect(status == 404)
        #expect(transport.requests.first?.url?.absoluteString == "http://mini.tailnet:8787/api/v1/apps/nope")
    }

    @Test func unparsableErrorBodyBecomesHTTPStatusCode() async throws {
        let transport = StubTransport(responses: [StubTransport.Response(status: 503, body: "<html>bad gateway</html>")])
        let api = HangarAPI(baseURL: Self.base, transport: transport)
        let error = await #expect(throws: HangarAPIError.self) { try await api.apps() }
        guard case .server(let apiError, 503) = error else { Issue.record("expected .server 503"); return }
        #expect(apiError.code == "http_503")
    }

    @Test func transportFailureIsWrapped() async throws {
        let api = HangarAPI(baseURL: Self.base, transport: StubTransport())
        let error = await #expect(throws: HangarAPIError.self) { try await api.machines() }
        guard case .transport = error else { Issue.record("expected .transport"); return }
    }

    @Test func deployPostsRequest() async throws {
        let queued = Self.build()
        let transport = StubTransport(responses: [try Self.json(queued, status: 202)])
        let api = HangarAPI(baseURL: Self.base, transport: transport)

        let build = try await api.deploy(DeployRequest(app: "legilo", workflow: "testflight", ref: "main", machine: "mini"))

        #expect(build == queued)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://mini.tailnet:8787/api/v1/builds")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONCoding.decoder.decode(DeployRequest.self, from: try #require(request.httpBody))
        #expect(body == DeployRequest(app: "legilo", workflow: "testflight", ref: "main", machine: "mini"))
    }

    @Test func pathSegmentsAndQueriesAreEncoded() async throws {
        let transport = StubTransport(responses: [
            StubTransport.Response(status: 204),
            try Self.json([Build]()),
            try Self.json([LogEntry]()),
        ])
        let api = HangarAPI(baseURL: URL(string: "http://mini:8787/")!, transport: transport)
        let jobID = UUID()

        try await api.setVariable("API_KEY", VariableInput(value: "x", isSecret: true), app: "my app")
        _ = try await api.builds(app: "legilo", limit: 20)
        _ = try await api.log(jobID: jobID, step: "post-action:testflight", tail: 40)

        let urls = transport.requests.map { $0.url?.absoluteString }
        #expect(urls[0] == "http://mini:8787/api/v1/apps/my%20app/variables/API_KEY")
        #expect(transport.requests[0].httpMethod == "PUT")
        #expect(urls[1] == "http://mini:8787/api/v1/builds?app=legilo&limit=20")
        #expect(urls[2] == "http://mini:8787/api/v1/jobs/\(jobID.uuidString)/log?step=post-action:testflight&tail=40")
    }

    @Test func eventsDecodeServerEventsFromFrames() async throws {
        let build = Self.build(status: .running)
        let data = String(decoding: try JSONCoding.encoder.encode(ServerEvent.build(build)), as: UTF8.self)
        let recorder = Recorder()
        let api = HangarAPI(
            baseURL: Self.base, transport: StubTransport(),
            openLines: Self.lines(": keep-alive\n\nevent: build\ndata: \(data)\n\n", recorder: recorder))

        var received: [ServerEvent] = []
        await #expect(throws: HangarAPIError.self) {
            for try await event in api.events() { received.append(event) }
        }
        #expect(received == [.build(build)])
        #expect(recorder.requests.first?.url?.absoluteString == "http://mini.tailnet:8787/api/v1/events")
    }

    @Test func followLogFlattensBatchesAndEndsCleanly() async throws {
        let jobID = UUID()
        let first = [LogEntry(t: Self.t0, step: "checkout", line: "cloning")]
        let second = [LogEntry(t: Self.t0, step: "archive", line: "a"), LogEntry(t: Self.t0, step: "archive", line: "b")]
        func frame(_ name: String, _ value: some Encodable) throws -> String {
            "event: \(name)\ndata: \(String(decoding: try JSONCoding.encoder.encode(value), as: UTF8.self))\n\n"
        }
        let job = Self.build().jobs[0]
        let text = try frame("log", first) + ": keep-alive\n\n" + frame("log", second) + frame("end", job)
        let recorder = Recorder()
        let api = HangarAPI(baseURL: Self.base, transport: StubTransport(), openLines: Self.lines(text, recorder: recorder))

        var entries: [LogEntry] = []
        for try await entry in api.followLog(jobID: jobID, step: "archive") { entries.append(entry) }

        #expect(entries == first + second)
        #expect(
            recorder.requests.first?.url?.absoluteString
                == "http://mini.tailnet:8787/api/v1/jobs/\(jobID.uuidString)/log?follow=1&step=archive")
    }

    @Test func followLogWithoutEndIsAnError() async throws {
        let api = HangarAPI(baseURL: Self.base, transport: StubTransport(), openLines: Self.lines(": keep-alive\n\n"))
        await #expect(throws: HangarAPIError.self) {
            for try await _ in api.followLog(jobID: UUID()) {}
        }
    }
}

extension HangarAPITests {
    @Test func undecodableSuccessBodyIsInvalidResponse() async throws {
        let api = HangarAPI(baseURL: Self.base, transport: StubTransport(responses: [StubTransport.Response(body: "{\"nope\":1}")]))
        let error = await #expect(throws: HangarAPIError.self) { try await api.apps() }
        guard case .invalidResponse = error else { Issue.record("expected .invalidResponse, got \(String(describing: error))"); return }
    }
}
