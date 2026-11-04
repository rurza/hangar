import Foundation
import HangarCore
import Testing

@testable import HangarWorker

private struct FailingTransport: HTTPTransport {
    var error: any Error
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw error }
}

/// `hangar-worker check`: one authenticated call that tells the install script whether this Mac is still enrolled.
@Suite struct WorkerCheckTests {
    static let configuration = WorkerConfiguration(
        serverURL: URL(string: "http://studio:8787")!, token: "secret-token-value", dataDirectory: "/tmp/w")
    static let machineJSON = #"""
        {"id":"8C606F06-B04B-4A91-8303-EEB30787B1FD","name":"mini-2","maxConcurrentJobs":1,"createdAt":"2026-11-04T19:50:02.881Z"}
        """#

    @Test func anAcceptedTokenExitsZeroWithTheMachine() async throws {
        let transport = StubTransport(responses: [.init(status: 200, body: Self.machineJSON)])
        let outcome = await WorkerCheck.run(configuration: Self.configuration, transport: transport)
        guard case .accepted(let machine) = outcome else {
            Issue.record("expected accepted, got \(outcome)")
            return
        }
        #expect(machine.name == "mini-2")
        #expect(outcome.exitCode == 0)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "http://studio:8787/api/v1/worker/me")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token-value")
    }

    @Test func aRefusedTokenExitsThree() async {
        let transport = StubTransport(responses: [.init(status: 401, body: #"{"code":"unauthorized","message":"x"}"#)])
        let outcome = await WorkerCheck.run(configuration: Self.configuration, transport: transport)
        #expect(outcome == .unauthorized)
        #expect(outcome.exitCode == 3)
    }

    @Test(arguments: [URLError.Code.cannotConnectToHost, .timedOut, .cannotFindHost, .notConnectedToInternet])
    func anUnreachableServerExitsFour(code: URLError.Code) async {
        let outcome = await WorkerCheck.run(
            configuration: Self.configuration, transport: FailingTransport(error: URLError(code)))
        guard case .unreachable = outcome else {
            Issue.record("expected unreachable, got \(outcome)")
            return
        }
        #expect(outcome.exitCode == 4)
    }

    @Test(arguments: [500, 404, 421])
    func anyOtherAnswerExitsOne(status: Int) async {
        let transport = StubTransport(responses: [.init(status: status, body: "nope")])
        let outcome = await WorkerCheck.run(configuration: Self.configuration, transport: transport)
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(outcome.exitCode == 1)
    }

    @Test func messagesNeverContainTheToken() async {
        let outcomes: [WorkerCheck.Outcome] = [
            await WorkerCheck.run(configuration: Self.configuration, transport: StubTransport(responses: [.init(status: 200, body: Self.machineJSON)])),
            await WorkerCheck.run(configuration: Self.configuration, transport: StubTransport(responses: [.init(status: 401)])),
            await WorkerCheck.run(configuration: Self.configuration, transport: FailingTransport(error: URLError(.timedOut))),
            await WorkerCheck.run(configuration: Self.configuration, transport: StubTransport(responses: [.init(status: 500, body: "secret-token-value")])),
        ]
        for outcome in outcomes {
            #expect(!outcome.message(server: Self.configuration.serverURL).contains("secret-token-value"))
        }
    }
}
