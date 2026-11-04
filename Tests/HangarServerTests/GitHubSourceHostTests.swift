import Foundation
import HangarCore
import Testing

@testable import HangarServer

@Suite struct GitHubSourceHostTests {
    func make(_ responses: [StubTransport.Response]) -> (GitHubSourceHost, StubTransport) {
        let transport = StubTransport(responses: responses)
        return (GitHubSourceHost(transport: transport), transport)
    }

    @Test func parsesHTTPSAndSSHRemotes() async throws {
        let urls = [
            "https://github.com/acme/legilo", "https://github.com/acme/legilo.git", "https://github.com/acme/legilo/",
            "git@github.com:acme/legilo.git", "git@github.com:acme/legilo",
        ]
        for url in urls {
            let (host, transport) = make([.init(body: #"{"sha":"abc123"}"#)])
            let sha = try await host.resolveCommit(repoURL: url, ref: "main", token: nil)
            #expect(sha == "abc123")
            #expect(transport.requests.first?.url?.absoluteString == "https://api.github.com/repos/acme/legilo/commits/main")
        }
    }

    @Test func rejectsUnsupportedRepositories() async throws {
        let (host, transport) = make([])
        await #expect(throws: SourceHostError.unsupportedRepository("https://gitlab.com/acme/legilo.git")) {
            _ = try await host.resolveCommit(repoURL: "https://gitlab.com/acme/legilo.git", ref: "main", token: nil)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func sendsBearerTokenAndHeaders() async throws {
        let (host, transport) = make([.init(body: #"{"sha":"abc"}"#)])
        _ = try await host.resolveCommit(repoURL: "https://github.com/a/b", ref: "main", token: "ghp_secret")
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "User-Agent") != nil)
    }

    @Test func omitsAuthorizationWithoutToken() async throws {
        let (host, transport) = make([.init(body: #"{"sha":"abc"}"#)])
        _ = try await host.resolveCommit(repoURL: "https://github.com/a/b", ref: "main", token: nil)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func refKeepsSlashesAndEscapesSegments() async throws {
        let (host, transport) = make([.init(body: #"{"sha":"abc"}"#)])
        _ = try await host.resolveCommit(repoURL: "https://github.com/a/b", ref: "feature/new thing", token: nil)
        #expect(transport.requests.first?.url?.absoluteString == "https://api.github.com/repos/a/b/commits/feature/new%20thing")
    }

    @Test func unknownRefIs404Or422() async throws {
        for status in [404, 422] {
            let (host, _) = make([.init(status: status, body: "{}")])
            await #expect(throws: SourceHostError.refNotFound("nope")) {
                _ = try await host.resolveCommit(repoURL: "https://github.com/a/b", ref: "nope", token: nil)
            }
        }
    }

    @Test func otherFailuresCarryStatusAndBody() async throws {
        let (host, _) = make([.init(status: 500, body: "boom")])
        await #expect(throws: SourceHostError.http(status: 500, body: "boom")) {
            _ = try await host.resolveCommit(repoURL: "https://github.com/a/b", ref: "main", token: nil)
        }
    }

    @Test func readFileReturnsContentsAtCommit() async throws {
        let (host, transport) = make([.init(body: "version: 1\n")])
        let text = try await host.readFile(repoURL: "https://github.com/a/b", commit: "abc", path: ".hangar.yml", token: "t")
        #expect(text == "version: 1\n")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/a/b/contents/.hangar.yml?ref=abc")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    }

    @Test func readFileReturnsNilOn404() async throws {
        let (host, _) = make([.init(status: 404, body: "{}")])
        let text = try await host.readFile(repoURL: "https://github.com/a/b", commit: "abc", path: ".hangar.yml", token: nil)
        #expect(text == nil)
    }

    @Test func readFileFailsOnOtherErrors() async throws {
        let (host, _) = make([.init(status: 403, body: "rate limited")])
        await #expect(throws: SourceHostError.http(status: 403, body: "rate limited")) {
            _ = try await host.readFile(repoURL: "https://github.com/a/b", commit: "abc", path: ".hangar.yml", token: nil)
        }
    }

    @Test func malformedOwnerOrRepoMakesNoRequest() async throws {
        for url in ["https://github.com/a b/c", "https://github.com/../c", "https://github.com/a/c?x=1", "https://github.com/a/#x", "https://github.com/a/.."] {
            let (host, transport) = make([])
            await #expect(throws: SourceHostError.unsupportedRepository(url)) {
                _ = try await host.resolveCommit(repoURL: url, ref: "main", token: nil)
            }
            #expect(transport.requests.isEmpty)
        }
    }

    @Test func dotSegmentsInRefsMakeNoRequest() async throws {
        for ref in ["../x", "a/./b", "a//b", "", "a/"] {
            let (host, transport) = make([])
            await #expect(throws: SourceHostError.refNotFound(ref)) {
                _ = try await host.resolveCommit(repoURL: "https://github.com/a/b", ref: ref, token: nil)
            }
            #expect(transport.requests.isEmpty)
        }
    }

    @Test func dotSegmentsInPathsMakeNoRequest() async throws {
        let (host, transport) = make([])
        await #expect(throws: SourceHostError.invalidPath("../secrets")) {
            _ = try await host.readFile(repoURL: "https://github.com/a/b", commit: "abc", path: "../secrets", token: nil)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func queryAndFragmentCharactersInRefsAreEscaped() async throws {
        let (host, transport) = make([.init(body: #"{"sha":"abc"}"#)])
        _ = try await host.resolveCommit(repoURL: "https://github.com/a/b", ref: "x?y#z", token: nil)
        #expect(transport.requests.first?.url?.absoluteString == "https://api.github.com/repos/a/b/commits/x%3Fy%23z")
    }
}
