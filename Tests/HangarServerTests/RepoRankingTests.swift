import Foundation
import Testing

/// The repository picker's ranking (Web/assets/repo-ranking.js), run in JXA.
@Suite(.timeLimit(.minutes(1))) struct RepoRankingTests {
    static let repos = """
        [
          {"fullName": "rurza/old-legilo-experiments", "pushedAt": "2026-10-30T00:00:00Z", "archived": false},
          {"fullName": "rurza/BatFi", "pushedAt": "2026-11-01T00:00:00Z", "archived": false},
          {"fullName": "rurza/hourly-beep", "pushedAt": "2025-01-01T00:00:00Z", "archived": false},
          {"fullName": "rurza/Legilo", "pushedAt": "2026-09-01T00:00:00Z", "archived": false},
          {"fullName": "rurza/Legilo-archive", "pushedAt": "2026-11-04T00:00:00Z", "archived": true},
          {"fullName": "rurza/dotfiles", "pushedAt": "2026-11-03T00:00:00Z", "archived": false, "description": "Shell setup"}
        ]
        """

    static func run(_ expression: String) throws -> String {
        try WorkflowYAMLRoundTripTests.runJXA(json: repos, files: ["repo-ranking.js"], expression)
    }

    @Test func appNameMatchComesFirst() throws {
        let output = try Self.run("(() => { const r = rankRepositories(input, { name: 'Legilo', bundleID: 'software.micropixels.legilo' }); return r.repos.map((x) => x.fullName).join(',') + '|' + r.suggested.fullName; })()")
        #expect(output == "rurza/Legilo,rurza/old-legilo-experiments,rurza/dotfiles,rurza/BatFi,rurza/hourly-beep,rurza/Legilo-archive|rurza/Legilo")
    }

    @Test func bundleIDLastComponent() throws {
        let output = try Self.run("rankRepositories(input, { name: 'Chime', bundleID: 'software.micropixels.Hourly-Beep' }).repos[0].fullName")
        #expect(output == "rurza/hourly-beep")
    }

    @Test func recencyWithoutHintsAndArchivedLast() throws {
        let output = try Self.run("(() => { const r = rankRepositories(input); return r.repos.map((x) => x.fullName).join(',') + '|' + String(r.suggested); })()")
        #expect(output == "rurza/dotfiles,rurza/BatFi,rurza/old-legilo-experiments,rurza/Legilo,rurza/hourly-beep,rurza/Legilo-archive|null")
    }

    @Test func filterAndParse() throws {
        #expect(try Self.run("filterRepositories(input, 'shell').map((x) => x.fullName).join(',')") == "rurza/dotfiles")
        #expect(try Self.run("filterRepositories(input, 'legilo arch').map((x) => x.fullName).join(',')") == "rurza/Legilo-archive")
        #expect(try Self.run("parseRepositoryURL('https://github.com/rurza/Legilo.git/').fullName") == "rurza/Legilo")
        #expect(try Self.run("String(parseRepositoryURL('https://gitlab.com/rurza/Legilo'))") == "null")
        #expect(try Self.run("String(parseRepositoryURL('https://github.com/rurza/..'))") == "null")
    }
}
