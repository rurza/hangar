import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

@Suite(.timeLimit(.minutes(1))) struct APITokensTests {
    private func bearer(_ secret: String, json: Bool = false) -> HTTPFields {
        var fields: HTTPFields = [.authorization: "Bearer \(secret)"]
        if json { fields[.contentType] = "application/json" }
        return fields
    }

    @Test func createListAndRevokeStoresOnlyTheHash() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            let created = try await client.execute(
                uri: "/api/v1/api-tokens", method: .post, headers: jsonHeaders,
                body: try body(CreateAPITokenRequest(name: "Claude", scope: .deploy))
            ) { response throws in
                #expect(response.status == .created)
                return try decode(CreateAPITokenResponse.self, response)
            }
            #expect(APIToken.isWellFormedSecret(created.secret))
            #expect(created.token.prefix == String(created.secret.prefix(8)))
            #expect(created.token.scope == .deploy)

            // The listing never carries the secret.
            try await client.execute(uri: "/api/v1/api-tokens", method: .get) { response throws in
                #expect(!String(buffer: response.body).contains(created.secret))
                #expect(try decode([APIToken].self, response).map(\.name) == ["Claude"])
            }
            let stored = try fixture.server.database.read { db in
                try String.fetchAll(db, sql: "SELECT token_hash FROM api_tokens")
            }
            #expect(stored.count == 1 && stored[0] != created.secret && stored[0].count == 64)

            try await client.execute(
                uri: "/api/v1/api-tokens", method: .post, headers: jsonHeaders,
                body: try body(CreateAPITokenRequest(name: "Claude", scope: .read))
            ) { response throws in
                #expect(response.status == .conflict)
                #expect(try decode(APIError.self, response).code == "token_exists")
            }

            try await client.execute(uri: "/api/v1/apps", method: .get, headers: bearer(created.secret)) {
                #expect($0.status == .ok)
            }
            try await client.execute(uri: "/api/v1/api-tokens/Claude", method: .delete) { #expect($0.status == .noContent) }
            try await client.execute(uri: "/api/v1/apps", method: .get, headers: bearer(created.secret)) { response throws in
                #expect(response.status == .unauthorized)
                #expect(try decode(APIError.self, response).code == "invalid_api_token")
            }
        }
    }

    @Test func emptyNameIsRefused() async throws {
        try await APIFixture().test { client in
            try await client.execute(
                uri: "/api/v1/api-tokens", method: .post, headers: jsonHeaders,
                body: try body(CreateAPITokenRequest(name: "  ", scope: .read))
            ) { response throws in
                #expect(response.status == .badRequest)
                #expect(try decode(APIError.self, response).code == "invalid_name")
            }
        }
    }

    @Test func unknownTokenNeverFallsBackToTheOpenAPI() async throws {
        let fake = "hgr_" + String(repeating: "A", count: 43)
        try await APIFixture().test { client in
            for secret in [fake, "hgr_short"] {
                try await client.execute(uri: "/api/v1/apps", method: .get, headers: bearer(secret)) { response throws in
                    #expect(response.status == .unauthorized)
                    #expect(try decode(APIError.self, response).code == "invalid_api_token")
                }
            }
            // Without a token, or with some other bearer value, the API answers as it always has.
            try await client.execute(uri: "/api/v1/apps", method: .get) { #expect($0.status == .ok) }
            try await client.execute(uri: "/api/v1/apps", method: .get, headers: bearer("machine-token")) {
                #expect($0.status == .ok)
            }
        }
    }

    @Test func scopesNest() async throws {
        let fixture = try APIFixture()
        let read = try fixture.server.apiTokens.create(name: "r", scope: .read).secret
        let deploy = try fixture.server.apiTokens.create(name: "d", scope: .deploy).secret
        let configure = try fixture.server.apiTokens.create(name: "c", scope: .configure).secret
        let app = CreateAppRequest(name: "Legilo", repoURL: "https://github.com/acme/legilo.git", appStoreConnectAppID: "42")
        try await fixture.test { client in
            for secret in [read, deploy] {
                try await client.execute(
                    uri: "/api/v1/apps", method: .post, headers: bearer(secret, json: true), body: try body(app)
                ) { response throws in
                    #expect(response.status == .forbidden)
                    #expect(try decode(APIError.self, response).code == "token_scope")
                }
            }
            try await client.execute(
                uri: "/api/v1/apps", method: .post, headers: bearer(configure, json: true), body: try body(app)
            ) { #expect($0.status == .created) }

            // A read token cannot deploy; the deploy token gets past the scope check to the deploy itself.
            let deployRequest = DeployRequest(app: "legilo", workflow: "release", ref: "main")
            try await client.execute(
                uri: "/api/v1/builds", method: .post, headers: bearer(read, json: true), body: try body(deployRequest)
            ) { #expect($0.status == .forbidden) }
            try await client.execute(
                uri: "/api/v1/builds", method: .post, headers: bearer(deploy, json: true), body: try body(deployRequest)
            ) { response throws in
                #expect(response.status != .forbidden && response.status != .unauthorized)
            }
            try await client.execute(uri: "/api/v1/builds", method: .get, headers: bearer(read)) { #expect($0.status == .ok) }
        }
    }

    @Test func tokensNeverReachSecretsMachinesOrTokens() async throws {
        let fixture = try APIFixture()
        let secret = try fixture.server.apiTokens.create(name: "c", scope: .configure).secret
        let refused: [(HTTPRequest.Method, String, ByteBuffer?)] = [
            (.put, "/api/v1/variables/X", try body(VariableInput(value: "v", isSecret: true))),
            (.delete, "/api/v1/variables/X", nil),
            (.post, "/api/v1/settings/github-token", try body(["token": "t"])),
            (.post, "/api/v1/machines", try body(CreateMachineRequest(name: "m"))),
            (.post, "/api/v1/machines/pairings", nil),
            (.delete, "/api/v1/machines/m", nil),
            (.get, "/api/v1/setup/asc-keys", nil),
            (.post, "/api/v1/setup/local-worker", nil),
            (.get, "/api/v1/api-tokens", nil),
            (.post, "/api/v1/api-tokens", try body(CreateAPITokenRequest(name: "more", scope: .configure))),
            (.delete, "/api/v1/api-tokens/c", nil),
        ]
        try await fixture.test { client in
            for (method, uri, payload) in refused {
                try await client.execute(uri: uri, method: method, headers: bearer(secret, json: payload != nil), body: payload) {
                    response throws in
                    #expect(response.status == .forbidden, "\(method) \(uri)")
                    #expect(try decode(APIError.self, response).code == "token_scope")
                }
            }
            try await client.execute(uri: "/api/v1/api-tokens/current", method: .get, headers: bearer(secret)) { response throws in
                let token = try decode(APIToken.self, response)
                #expect(token.name == "c" && token.scope == .configure)
            }
        }
        #expect(try fixture.server.apiTokens.all().count == 1)
    }

    @Test func aTokenDoesNotExcuseACrossSiteRequest() async throws {
        let fixture = try APIFixture()
        let secret = try fixture.server.apiTokens.create(name: "c", scope: .configure).secret
        try await fixture.test { client in
            var headers = bearer(secret, json: true)
            headers[CrossSiteGuard.secFetchSite] = "cross-site"
            try await client.execute(
                uri: "/api/v1/apps", method: .post, headers: headers,
                body: try body(CreateAppRequest(name: "X", repoURL: "https://github.com/a/x", appStoreConnectAppID: "1"))
            ) { response throws in
                #expect(try decode(APIError.self, response).code == "cross_site_request")
            }
        }
    }

    @Test func lastUsedIsRecordedAtMostOnceAMinute() throws {
        let fixture = try APIFixture()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let secret = try fixture.server.apiTokens.create(name: "r", scope: .read, now: start).secret
        #expect(try fixture.server.apiTokens.authenticate(secret: secret, now: start)?.lastUsedAt == start)
        #expect(try fixture.server.apiTokens.authenticate(secret: secret, now: start + 30)?.lastUsedAt == start)
        #expect(try fixture.server.apiTokens.authenticate(secret: secret, now: start + 61)?.lastUsedAt == start + 61)
    }

    @Test func policyTable() {
        #expect(APITokenPolicy.required(method: .get, path: "apps/legilo/deploy-check") == .read)
        #expect(APITokenPolicy.required(method: .get, path: "events") == .read)
        #expect(APITokenPolicy.required(method: .get, path: "setup") == .read)
        #expect(APITokenPolicy.required(method: .get, path: "setup/github") == nil)
        #expect(APITokenPolicy.required(method: .post, path: "builds") == .deploy)
        #expect(APITokenPolicy.required(method: .post, path: "builds/x/cancel") == .deploy)
        #expect(APITokenPolicy.required(method: .put, path: "apps/x/workflow-file") == .configure)
        #expect(APITokenPolicy.required(method: .delete, path: "apps/x/workflow-file") == .configure)
        #expect(APITokenPolicy.required(method: .post, path: "apps/x/beta-groups") == .configure)
        #expect(APITokenPolicy.required(method: .put, path: "apps/x/variables/Y") == nil)
        #expect(APITokenPolicy.required(method: .post, path: "enroll") == nil)
        #expect(APITokenScope.configure.includes(.read) && !APITokenScope.read.includes(.deploy))
    }
}
