import Foundation
import Testing

/// What the Machines page and Settings say about Hangar's disk use and retention (Web/assets/disk-usage.js), run in
/// JXA.
@Suite(.timeLimit(.minutes(1))) struct DiskUsageTextTests {
    static func run(_ json: String, _ expression: String) throws -> String {
        try WorkflowYAMLRoundTripTests.runJXA(json: json, files: ["disk-usage.js"], expression)
    }

    @Test func amountsReadAsFinderCountsThem() throws {
        #expect(try Self.run("[50.71, 1.31, 0.12, 0]", "input.map(gbText).join(' | ')") == "51 GB | 1.3 GB | 120 MB | 0 MB")
        #expect(try Self.run("[null]", "gbText(input[0])") == "–")
    }

    @Test func aMachinesUsageHasItsPiecesAsDetail() throws {
        let usage = #"{"totalGB": 50.7, "parts": [{"label": "VM images", "gb": 49.4}, {"label": "Workspaces", "gb": 1.31}]}"#
        #expect(try Self.run(usage, "(() => { const t = diskUsageText(input); return `${t.value} | ${t.detail}`; })()")
            == "51 GB | VM images 49 GB · Workspaces 1.3 GB")
        #expect(try Self.run("{}", "String(diskUsageText(input.diskUsage))") == "null")
    }

    @Test func theRetentionPolicyReadsAsASentence() throws {
        #expect(try Self.run(#"{"keepBuildsPerApp": 5, "keepDays": 7, "maxGB": 10}"#, "retentionText(input)")
            == "Keeps the logs and artifacts of each app’s last 5 builds and of every build from the last 7 days, up to 10 GB in all; past that the oldest go first.")
        #expect(try Self.run(#"{"keepBuildsPerApp": 1, "keepDays": 1, "maxGB": 2.5}"#, "retentionText(input)")
            == "Keeps the logs and artifacts of each app’s latest build and of every build from the last day, up to 2.5 GB in all; past that the oldest go first.")
    }
}
