import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

/// Pairing codes (`POST /machines/pairings`) and enrolling a machine with one (`POST /enroll`).
@Suite(.timeLimit(.minutes(1))) struct EnrollAPITests {
    /// What curl sends: JSON, no Origin, no Sec-Fetch-Site.
    static func enroll(
        _ client: any TestClientProtocol, code: String, name: String, maxConcurrentJobs: Int? = nil
    ) async throws -> TestResponse {
        try await client.execute(
            uri: "/api/v1/enroll", method: .post, headers: jsonHeaders,
            body: try body(EnrollRequest(code: code, name: name, maxConcurrentJobs: maxConcurrentJobs)))
    }

    static func newCode(_ client: any TestClientProtocol) async throws -> Pairing {
        try await client.execute(uri: "/api/v1/machines/pairings", method: .post) { response throws in
            #expect(response.status == .created)
            return try decode(Pairing.self, response)
        }
    }

    @Test func aValidCodeCreatesTheMachineAndReturnsItsTokenOnce() async throws {
        let fixture = try APIFixture()
        let events = fixture.server.events.subscribe()
        try await fixture.test { client in
            let pairing = try await Self.newCode(client)
            #expect(pairing.code.wholeMatch(of: /[A-Z2-9]{4}-[A-Z2-9]{4}/) != nil)
            let response = try await Self.enroll(client, code: pairing.code.lowercased(), name: "mini-2", maxConcurrentJobs: 2)
            #expect(response.status == .created)
            let created = try decode(CreateMachineResponse.self, response)
            #expect(created.machine.name == "mini-2")
            #expect(created.machine.maxConcurrentJobs == 2)
            #expect(created.token.count >= 40)
            #expect(try fixture.server.machines.authenticate(token: created.token)?.id == created.machine.id)

            try await client.execute(uri: "/api/v1/machines", method: .get) { response throws in
                let machines = try decode([Machine].self, response)
                #expect(machines.map(\.name) == ["mini-2"])
                #expect(!String(buffer: response.body).contains(created.token))
            }
            // The code is spent.
            let again = try await Self.enroll(client, code: pairing.code, name: "mini-3")
            #expect(again.status == .forbidden)
            #expect(try decode(APIError.self, again).code == "invalid_pairing_code")
        }
        var iterator = events.makeAsyncIterator()
        guard case .server(.machine(let machine))? = await iterator.next() else {
            Issue.record("expected a machine event")
            return
        }
        #expect(machine.name == "mini-2")
    }

    @Test func maxConcurrentJobsDefaultsToOne() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            let pairing = try await Self.newCode(client)
            let response = try await Self.enroll(client, code: pairing.code, name: "mini")
            #expect(response.status == .created)
            #expect(try decode(CreateMachineResponse.self, response).machine.maxConcurrentJobs == 1)
        }
    }

    @Test(arguments: ["", "ABCD-EFGH", "not a code at all", "ABCD-EFGH-JKLM"])
    func anUnknownCodeIsForbidden(code: String) async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            _ = try await Self.newCode(client)
            let response = try await Self.enroll(client, code: code, name: "mini")
            #expect(response.status == .forbidden)
            #expect(try decode(APIError.self, response).code == "invalid_pairing_code")
        }
        #expect(try fixture.server.machines.all().isEmpty)
    }

    @Test func anExpiredCodeIsForbidden() async throws {
        let clock = ManualClock()
        let fixture = try APIFixture(now: { clock.now })
        try await fixture.test { client in
            let pairing = try await Self.newCode(client)
            clock.advance(by: 15 * 60)
            let response = try await Self.enroll(client, code: pairing.code, name: "mini")
            #expect(response.status == .forbidden)
            #expect(try decode(APIError.self, response).code == "invalid_pairing_code")
        }
        #expect(try fixture.server.machines.all().isEmpty)
    }

    @Test func aTakenNameIsAConflictAndKeepsTheCode() async throws {
        let fixture = try APIFixture()
        _ = try fixture.server.machines.create(name: "mini")
        try await fixture.test { client in
            let pairing = try await Self.newCode(client)
            let taken = try await Self.enroll(client, code: pairing.code, name: "mini")
            #expect(taken.status == .conflict)
            #expect(try decode(APIError.self, taken).code == "machine_exists")
            let retry = try await Self.enroll(client, code: pairing.code, name: "mini-2")
            #expect(retry.status == .created)
        }
    }

    @Test func anInvalidNameIsABadRequestAndKeepsTheCode() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            let pairing = try await Self.newCode(client)
            let blank = try await Self.enroll(client, code: pairing.code, name: "  ")
            #expect(blank.status == .badRequest)
            #expect(try decode(APIError.self, blank).code == "invalid_name")
            let zero = try await Self.enroll(client, code: pairing.code, name: "mini", maxConcurrentJobs: 0)
            #expect(zero.status == .badRequest)
            #expect(try await Self.enroll(client, code: pairing.code, name: "mini").status == .created)
        }
    }

    @Test func theEleventhAttemptAfterTenFailuresIsRateLimited() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            let pairing = try await Self.newCode(client)
            for _ in 0..<10 {
                #expect(try await Self.enroll(client, code: "WRNG-CODE", name: "mini").status == .forbidden)
            }
            let limited = try await Self.enroll(client, code: pairing.code, name: "mini")
            #expect(limited.status == .tooManyRequests)
            #expect(try decode(APIError.self, limited).code == "too_many_attempts")
        }
        #expect(try fixture.server.machines.all().isEmpty)
    }

    @Test func pairingsRefuseCrossSiteRequests() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            for headers: HTTPFields in [
                [.origin: "https://evil.example"], [CrossSiteGuard.secFetchSite: "cross-site"],
            ] {
                try await client.execute(uri: "/api/v1/machines/pairings", method: .post, headers: headers) { response throws in
                    #expect(response.status == .forbidden)
                    #expect(try decode(APIError.self, response).code == "cross_site_request")
                }
            }
            // The web UI's own request passes.
            try await client.execute(
                uri: "/api/v1/machines/pairings", method: .post,
                headers: [.origin: "http://localhost", CrossSiteGuard.secFetchSite: "same-origin"]
            ) { response throws in
                #expect(response.status == .created)
            }
        }
        #expect(fixture.server.pairings.liveCount == 1)
    }

    @Test func enrollRefusesCrossSiteRequests() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            let pairing = try await Self.newCode(client)
            try await client.execute(
                uri: "/api/v1/enroll", method: .post,
                headers: [.contentType: "text/plain", .origin: "https://evil.example"],
                body: try body(EnrollRequest(code: pairing.code, name: "mini"))
            ) { response throws in
                #expect(response.status == .forbidden)
            }
            #expect(try await Self.enroll(client, code: pairing.code, name: "mini").status == .created)
        }
    }
}
