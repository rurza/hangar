import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

/// `GET /api/v1/worker/me`: the machine a token belongs to, for `hangar-worker check`.
@Suite(.timeLimit(.minutes(1))) struct WorkerMeTests {
    @Test func answersTheTokensMachineWithoutTheToken() async throws {
        let fixture = try APIFixture()
        let (machine, token) = try fixture.server.machines.create(name: "studio", maxConcurrentJobs: 2)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/worker/me", method: .get, headers: WorkerAPITests.auth(token)) {
                response throws in
                #expect(response.status == .ok)
                let me = try decode(Machine.self, response)
                #expect(me.id == machine.id)
                #expect(me.name == "studio")
                #expect(!String(buffer: response.body).contains(token))
            }
        }
    }

    @Test(arguments: ["", "Bearer wrong", "Bearer "])
    func refusesAMissingOrUnknownToken(authorization: String) async throws {
        let fixture = try APIFixture()
        _ = try fixture.server.machines.create(name: "studio")
        try await fixture.test { client in
            let headers: HTTPFields = authorization.isEmpty ? [:] : [.authorization: authorization]
            try await client.execute(uri: "/api/v1/worker/me", method: .get, headers: headers) { response throws in
                #expect(response.status == .unauthorized)
                #expect(try decode(APIError.self, response).code == "unauthorized")
            }
        }
    }

    @Test func aRemovedMachinesTokenIsRefused() async throws {
        let fixture = try APIFixture()
        let (machine, token) = try fixture.server.machines.create(name: "studio")
        try fixture.server.machines.delete(id: machine.id)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/worker/me", method: .get, headers: WorkerAPITests.auth(token)) {
                response throws in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
