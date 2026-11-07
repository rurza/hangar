import Foundation
import HTTPTypes
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

/// `/mcp`: the agent tools over HTTP, with the agent's API token, refusing an owner token as `hangar mcp` does.
@Suite struct MCPRoutesTests {
    private func headers(_ secret: String?) -> HTTPFields {
        var fields: HTTPFields = [.contentType: "application/json", .accept: "application/json, text/event-stream"]
        if let secret { fields[.authorization] = "Bearer \(secret)" }
        return fields
    }

    private func message(_ json: String) -> ByteBuffer { ByteBuffer(string: json) }

    private static let initialize =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#

    @Test func anAgentTokenInitializesAndListsTheTools() async throws {
        let fixture = try APIFixture()
        let secret = try fixture.server.apiTokens.create(name: "agents", scope: .deploy).secret
        try await fixture.test { client in
            try await client.execute(uri: "/mcp", method: .post, headers: headers(secret), body: message(Self.initialize)) {
                response throws in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json")
                let text = String(buffer: response.body)
                #expect(text.contains(#""protocolVersion":"2025-06-18""#))
                #expect(text.contains(#""name":"hangar""#))
            }
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(secret),
                body: message(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            ) { response throws in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains(#""name":"start_build""#))
            }
            // A notification has no answer.
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(secret),
                body: message(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            ) { #expect($0.status == .accepted) }
        }
    }

    /// The tools call the API with the agent's own token, so its scope decides what they may do.
    @Test func aToolCallsTheAPIWithTheAgentsToken() async throws {
        let transport = StubTransport(responses: [.init(body: "[]")])
        let fixture = try APIFixture(mcpTransport: transport)
        let secret = try fixture.server.apiTokens.create(name: "agents", scope: .deploy).secret
        try await fixture.test { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: headers(secret),
                body: message(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}"#)
            ) { response throws in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains(#""isError":false"#))
            }
        }
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/api/v1/apps")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)")
    }

    @Test func noTokenAnUnknownOneAndAnOwnerTokenAreRefused() async throws {
        let fixture = try APIFixture()
        let owner = try fixture.server.apiTokens.create(name: "mine", scope: .owner).secret
        try await fixture.test { client in
            for secret in [nil, "hgr_unknown"] {
                try await client.execute(uri: "/mcp", method: .post, headers: headers(secret), body: message(Self.initialize)) {
                    #expect($0.status == .unauthorized)
                    #expect($0.headers[.wwwAuthenticate]?.hasPrefix("Bearer") == true)
                }
            }
            try await client.execute(uri: "/mcp", method: .post, headers: headers(owner), body: message(Self.initialize)) {
                response throws in
                #expect(response.status == .forbidden)
                #expect(String(buffer: response.body).contains("owner token"))
            }
        }
    }

    /// No server-sent stream and no session: the transport lets a server answer 405.
    @Test func getAndDeleteAreNotAllowed() async throws {
        let fixture = try APIFixture()
        let secret = try fixture.server.apiTokens.create(name: "agents", scope: .deploy).secret
        try await fixture.test { client in
            for method in [HTTPRequest.Method.get, .delete] {
                try await client.execute(uri: "/mcp", method: method, headers: headers(secret)) {
                    #expect($0.status == .methodNotAllowed)
                    #expect($0.headers[.allow] == "POST")
                }
            }
        }
    }

    /// A page on another site cannot make the browser post to it.
    @Test func aCrossSitePostIsRefused() async throws {
        let fixture = try APIFixture()
        let secret = try fixture.server.apiTokens.create(name: "agents", scope: .deploy).secret
        var fields = headers(secret)
        fields[HTTPField.Name("Sec-Fetch-Site")!] = "cross-site"
        let crossSite = fields
        try await fixture.test { client in
            try await client.execute(uri: "/mcp", method: .post, headers: crossSite, body: message(Self.initialize)) {
                #expect($0.status == .forbidden)
            }
        }
    }
}
