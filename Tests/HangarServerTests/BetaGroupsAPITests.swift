import CryptoKit
import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

/// `GET` and `POST /apps/{id}/beta-groups`, through the live App Store Connect client over a `StubTransport`.
@Suite(.timeLimit(.minutes(1))) struct BetaGroupsAPITests {
    private static let groupsPage = """
        {"data":[
         {"type":"betaGroups","id":"g2","attributes":{"name":"Public","isInternalGroup":false}},
         {"type":"betaGroups","id":"g1","attributes":{"name":"Internal Testers","isInternalGroup":true}},
         {"type":"betaGroups","id":"g3","attributes":{"name":"Designers","isInternalGroup":true}}
        ]}
        """
    private static let created = """
        {"data":{"type":"betaGroups","id":"g9","attributes":{"name":"QA","isInternalGroup":true}}}
        """

    /// A server whose App Store Connect client is the live one, answering from `transport`.
    private func fixture(_ transport: StubTransport, configured: Bool = true) throws -> APIFixture {
        let key = P256.Signing.PrivateKey().pemRepresentation
        let fixture = try APIFixture(appStoreConnectFactory: { credentials in
            LiveAppStoreConnectClient(credentials: credentials, transport: transport)
        })
        if configured {
            for (name, value) in [("HANGAR_ASC_KEY_ID", "KEY123"), ("HANGAR_ASC_ISSUER_ID", "issuer"), ("HANGAR_ASC_KEY_PATH", key)] {
                try fixture.server.variables.set(scope: .global, name: name, input: VariableInput(value: value, isSecret: true))
            }
        }
        try fixture.createApp()  // appStoreConnectAppID "42"
        return fixture
    }

    @Test func listsTheAppsGroupsInternalFirst() async throws {
        let transport = StubTransport(responses: [StubTransport.Response(body: Self.groupsPage)])
        let fixture = try fixture(transport)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/beta-groups", method: .get) { response throws in
                #expect(response.status == .ok)
                #expect(try decode([BetaGroup].self, response) == [
                    BetaGroup(id: "g3", name: "Designers", isInternal: true),
                    BetaGroup(id: "g1", name: "Internal Testers", isInternal: true),
                    BetaGroup(id: "g2", name: "Public", isInternal: false),
                ])
            }
        }
        let url = try #require(transport.requests.first?.url)
        #expect(url.path == "/v1/betaGroups")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "filter[app]", value: "42")) == true)
    }

    @Test func withoutAKeyIs409() async throws {
        let transport = StubTransport()
        let fixture = try fixture(transport, configured: false)
        try await fixture.test { client in
            for method in [HTTPRequest.Method.get, .post] {
                try await client.execute(
                    uri: "/api/v1/apps/legilo/beta-groups", method: method, headers: jsonHeaders,
                    body: method == .post ? try body(CreateBetaGroupRequest(name: "QA")) : nil
                ) { response throws in
                    #expect(response.status == .conflict)
                    #expect(try decode(APIError.self, response).code == "asc_not_configured")
                }
            }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func unknownAppIs404() async throws {
        let fixture = try fixture(StubTransport())
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/nope/beta-groups", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test func createsAnInternalGroupOfTheApp() async throws {
        let transport = StubTransport(responses: [StubTransport.Response(status: 201, body: Self.created)])
        let fixture = try fixture(transport)
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/apps/legilo/beta-groups", method: .post, headers: jsonHeaders,
                body: try body(CreateBetaGroupRequest(name: "  QA  "))
            ) { response throws in
                #expect(response.status == .created)
                #expect(try decode(BetaGroup.self, response) == BetaGroup(id: "g9", name: "QA", isInternal: true))
            }
        }
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/betaGroups")
        let httpBody = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let data = try #require(json["data"] as? [String: Any])
        let attributes = try #require(data["attributes"] as? [String: Any])
        #expect(attributes["name"] as? String == "QA")
        #expect(attributes["isInternalGroup"] as? Bool == true)
        let app = try #require((data["relationships"] as? [String: Any])?["app"] as? [String: Any])
        #expect((app["data"] as? [String: String]) == ["type": "apps", "id": "42"])
    }

    @Test func refusesAnEmptyName() async throws {
        let transport = StubTransport()
        let fixture = try fixture(transport)
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/apps/legilo/beta-groups", method: .post, headers: jsonHeaders,
                body: try body(CreateBetaGroupRequest(name: "   "))
            ) { response throws in
                #expect(response.status == .badRequest)
                #expect(try decode(APIError.self, response).code == "invalid_request")
            }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func showsAppStoreConnectsRefusalVerbatim() async throws {
        let refusal = #"{"errors":[{"status":"409","code":"ENTITY_ERROR","title":"The request entity is invalid","detail":"A group with the name 'QA' already exists."}]}"#
        let transport = StubTransport(responses: [StubTransport.Response(status: 409, body: refusal)])
        let fixture = try fixture(transport)
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/apps/legilo/beta-groups", method: .post, headers: jsonHeaders,
                body: try body(CreateBetaGroupRequest(name: "QA"))
            ) { response throws in
                #expect(response.status == .badGateway)
                let error = try decode(APIError.self, response)
                #expect(error.code == "asc_refused")
                #expect(error.message == "App Store Connect: A group with the name 'QA' already exists.")
            }
        }
    }

    @Test func listingFailureSaysWhy() async throws {
        let transport = StubTransport(responses: [StubTransport.Response(status: 401, body: #"{"errors":[{"title":"Authentication credentials are missing or invalid."}]}"#)])
        let fixture = try fixture(transport)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/beta-groups", method: .get) { response throws in
                #expect(response.status == .badGateway)
                #expect(try decode(APIError.self, response).message == "App Store Connect: Authentication credentials are missing or invalid.")
            }
        }
    }
}
