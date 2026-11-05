import Foundation
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

@Suite(.timeLimit(.minutes(1))) struct BranchesAPITests {
    @Test func listsBranchesWithTheDefaultFirstAndCachesThem() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        fixture.host.state.withLock {
            $0.branches = RepositoryBranches(defaultBranch: "main", branches: ["develop", "feature/x", "main"])
        }
        try fixture.server.variables.set(scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "ghp-x", isSecret: true))
        try await fixture.test { client in
            for _ in 0..<2 {
                try await client.execute(uri: "/api/v1/apps/legilo/branches", method: .get) { response throws in
                    #expect(response.status == .ok)
                    let branches = try decode(RepositoryBranches.self, response)
                    #expect(branches == RepositoryBranches(defaultBranch: "main", branches: ["main", "develop", "feature/x"]))
                    #expect(!String(buffer: response.body).contains("ghp-x"))
                }
            }
        }
        let state = fixture.host.state.withLock { $0 }
        #expect(state.branchReads == 1)
        #expect(state.tokens == ["ghp-x"])
    }

    @Test func aGitHubFailureIsAnErrorAndNotCached() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        fixture.host.state.withLock { $0.branchesError = .http(status: 401, body: "bad credentials") }
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/branches", method: .get) { response throws in
                #expect(try decode(APIError.self, response).code == "github_unauthorized")
            }
            fixture.host.state.withLock {
                $0.branchesError = nil
                $0.branches = RepositoryBranches(defaultBranch: "trunk", branches: ["trunk"])
            }
            try await client.execute(uri: "/api/v1/apps/legilo/branches", method: .get) { response throws in
                #expect(try decode(RepositoryBranches.self, response).defaultBranch == "trunk")
            }
        }
    }

    @Test func aMissingWorkflowFileNamesTheShortCommit() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        fixture.host.state.withLock { $0.files[WorkflowFile.path] = nil }
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/workflows", method: .get) { response throws in
                let error = try decode(APIError.self, response)
                #expect(error.code == "workflow_file_missing")
                #expect(error.message == "Commit 0123456 has no .hangar.yml.")
            }
        }
    }
}

@Suite struct GitHubBranchesTests {
    @Test func readsTheDefaultBranchAndEveryBranchName() async throws {
        let transport = StubTransport(responses: [
            .init(body: #"{"default_branch":"main","full_name":"a/b"}"#),
            .init(body: #"[{"name":"develop","commit":{"sha":"1"}},{"name":"main","commit":{"sha":"2"}}]"#),
        ])
        let host = GitHubSourceHost(transport: transport)
        let branches = try await host.branches(repoURL: "https://github.com/a/b.git", token: "t")
        #expect(branches == RepositoryBranches(defaultBranch: "main", branches: ["main", "develop"]))
        #expect(transport.requests.map { $0.url?.absoluteString } == [
            "https://api.github.com/repos/a/b", "https://api.github.com/repos/a/b/branches?per_page=100",
        ])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer t" })
    }

    @Test func aMissingRepositoryIsAnError() async throws {
        let host = GitHubSourceHost(transport: StubTransport(responses: [.init(status: 404, body: "{}")]))
        await #expect(throws: SourceHostError.http(status: 404, body: "{}")) {
            _ = try await host.branches(repoURL: "https://github.com/a/b", token: nil)
        }
    }
}
