import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

/// What a leaked deploy or configure token can make the server build (security review M3).
@Suite(.timeLimit(.minutes(1))) struct TokenDeployTests {
    private static let sha = "0123456789abcdef0123456789abcdef01234567"

    private func deploy(_ client: any TestClientProtocol, ref: String, token: String?) async throws -> TestResponse {
        var headers = jsonHeaders
        if let token { headers[.authorization] = "Bearer \(token)" }
        return try await client.execute(
            uri: "/api/v1/builds", method: .post, headers: headers,
            body: try body(DeployRequest(app: "legilo", workflow: "testflight", ref: ref)))
    }

    @Test func aTokenDeploysOnlyTheAppsOwnBranchesAndTags() async throws {
        let fixture = try APIFixture(ownerCheck: FixedOwner(nil))
        try fixture.createApp()
        fixture.host.state.withLock { $0.tags = ["v1.2"] }
        let (_, token) = try fixture.server.apiTokens.create(name: "agent", scope: .deploy)
        try await fixture.test { client in
            for ref in ["main", "v1.2"] {
                let response = try await deploy(client, ref: ref, token: token)
                #expect(response.status == .accepted, "\(ref)")
            }
            for ref in [Self.sha, "pull/1/head", "refs/pull/1/head", "abc1234"] {
                let response = try await deploy(client, ref: ref, token: token)
                #expect(response.status == .badRequest, "\(ref)")
                let error = try decode(APIError.self, response)
                #expect(error.code == "ref_not_allowed")
            }
        }
        // A token deploy never asks the host to resolve a free-form ref.
        #expect(fixture.host.state.withLock { $0.refs.isEmpty })
    }

    @Test func theOwnerMayDeployAnyCommit() async throws {
        let fixture = try APIFixture(ownerCheck: FixedOwner("owner@github"))
        try fixture.createApp()
        try await fixture.test { client in
            let response = try await deploy(client, ref: Self.sha, token: nil)
            #expect(response.status == .accepted)
        }
        #expect(fixture.host.state.withLock { $0.refs } == [Self.sha])
    }

    @Test func noTokenCanAddAnApp() async throws {
        let fixture = try APIFixture(ownerCheck: FixedOwner(nil))
        let (_, token) = try fixture.server.apiTokens.create(name: "agent", scope: .configure)
        let input = CreateAppRequest(name: "Evil", repoURL: "https://github.com/attacker/evil", appStoreConnectAppID: "1")
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/apps", method: .post, headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: try body(input)
            ) { #expect($0.status == .forbidden) }
        }
        let apps = try fixture.server.apps.all()
        #expect(apps.isEmpty)
    }

    @Test func anAppNeedsAGitHubRepositoryURL() async throws {
        let fixture = try APIFixture()
        let input = CreateAppRequest(name: "Typo", repoURL: "github.com/acme", appStoreConnectAppID: "1")
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps", method: .post, headers: jsonHeaders, body: try body(input)) { response in
                #expect(response.status == .badRequest)
                let error = try decode(APIError.self, response)
                #expect(error.code == "invalid_repository")
            }
        }
    }
}
