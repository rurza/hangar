import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing

@testable import HangarServer

private let token = "ghp_SECRET_token_123"

private func repoJSON(_ name: String, private isPrivate: Bool = false, archived: Bool = false) -> String {
    """
    {"full_name": "rurza/\(name)", "html_url": "https://github.com/rurza/\(name)", "private": \(isPrivate),
     "default_branch": "main", "description": \(name == "Legilo" ? "\"Reading app\"" : "null"),
     "pushed_at": "2026-10-01T12:00:00Z", "archived": \(archived), "owner": {"login": "rurza"}}
    """
}

private func page(_ names: [String], next: String? = nil) -> StubTransport.Response {
    StubTransport.Response(
        body: "[" + names.map { repoJSON($0) }.joined(separator: ",") + "]",
        headers: next.map { ["Link": "<\($0)>; rel=\"next\", <https://api.github.com/user/repos?page=9>; rel=\"last\""] } ?? [:])
}

/// A wall clock tests move by hand.
private final class RepoListClock: Sendable {
    let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: @Sendable () -> Date { { self.date.withLock { $0 } } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@Suite(.timeLimit(.minutes(1))) struct GitHubReposTests {
    @Test func followsLinkHeaderPages() async throws {
        let transport = StubTransport(responses: [
            page(["Legilo", "BatFi"], next: "https://api.github.com/user/repos?per_page=100&page=2"),
            page(["hourly-beep"]),
        ])
        let repos = try await GitHubRepositories(transport: transport).repositories(token: token)
        #expect(repos.map(\.fullName) == ["rurza/Legilo", "rurza/BatFi", "rurza/hourly-beep"])
        #expect(repos[0] == GitHubRepo(
            fullName: "rurza/Legilo", htmlURL: "https://github.com/rurza/Legilo", isPrivate: false, defaultBranch: "main",
            description: "Reading app", pushedAt: ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z"), archived: false))
        let urls = transport.requests.map { $0.url?.absoluteString }
        #expect(urls == [
            "https://api.github.com/user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member",
            "https://api.github.com/user/repos?per_page=100&page=2",
        ])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" })
    }

    @Test func doesNotFollowLinksOffGitHub() async throws {
        let transport = StubTransport(responses: [page(["Legilo"], next: "https://evil.example/user/repos?page=2")])
        let repos = try await GitHubRepositories(transport: transport).repositories(token: token)
        #expect(repos.count == 1)
        #expect(transport.requests.count == 1)
    }

    @Test func stopsAfterTenPages() async throws {
        let transport = StubTransport(responses: (0..<12).map { page(["r\($0)"], next: "https://api.github.com/user/repos?page=\($0 + 2)") })
        let repos = try await GitHubRepositories(transport: transport).repositories(token: token)
        #expect(repos.count == 10)
        #expect(transport.requests.count == 10)
    }

    @Test func cachesForFiveMinutesPerToken() async throws {
        let clock = RepoListClock()
        let transport = StubTransport(responses: [page(["Legilo"]), page(["BatFi"]), page(["Other"])])
        let github = GitHubRepositories(transport: transport, now: clock.now)
        #expect(try await github.repositories(token: token).map(\.fullName) == ["rurza/Legilo"])
        clock.advance(299)
        #expect(try await github.repositories(token: token).map(\.fullName) == ["rurza/Legilo"])
        #expect(transport.requests.count == 1)
        // A new token is not served the old token's list.
        #expect(try await github.repositories(token: "ghp_other").map(\.fullName) == ["rurza/BatFi"])
        clock.advance(2)
        #expect(try await github.repositories(token: "ghp_other").map(\.fullName) == ["rurza/BatFi"])
        clock.advance(300)
        #expect(try await github.repositories(token: "ghp_other").map(\.fullName) == ["rurza/Other"])
        #expect(transport.requests.count == 3)
    }

    @Test func unauthorizedNeverCarriesTheToken() async throws {
        let transport = StubTransport(responses: [.init(status: 401, body: #"{"message":"Bad credentials \#(token)"}"#)])
        do {
            _ = try await GitHubRepositories(transport: transport).repositories(token: token)
            Issue.record("expected an error")
        } catch {
            let (status, body) = APIErrorMapping.map(error)
            #expect(status == .badGateway)
            #expect(body.code == "github_unauthorized")
            #expect(!body.message.contains(token))
            #expect(!"\(error)".contains(token))
            #expect(!String(reflecting: error).contains(token))
        }
    }

    @Test func routeWithoutTokenIs409() async throws {
        let fixture = try APIFixture()
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/github/repos", method: .get) { response throws in
                #expect(response.status == .conflict)
                let error = try decode(APIError.self, response)
                #expect(error.code == "github_not_configured")
                #expect(error.message == "Set a GitHub token in Settings first.")
            }
        }
    }

    @Test func routeListsAndMaps401To502() async throws {
        let transport = StubTransport(responses: [page(["Legilo"]), .init(status: 401, body: "{}")])
        let fixture = try APIFixture(githubTransport: transport)
        try fixture.server.variables.set(scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: token, isSecret: true))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/github/repos", method: .get) { response throws in
                #expect(response.status == .ok)
                #expect(try decode([GitHubRepo].self, response).map(\.fullName) == ["rurza/Legilo"])
                #expect(!String(buffer: response.body).contains(token))
            }
        }
        // A changed token drops the cached list.
        try fixture.server.variables.set(scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "ghp_revoked", isSecret: true))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/github/repos", method: .get) { response throws in
                #expect(response.status == .badGateway)
                #expect(try decode(APIError.self, response).code == "github_unauthorized")
                #expect(!String(buffer: response.body).contains("ghp_revoked"))
            }
        }
    }
}
