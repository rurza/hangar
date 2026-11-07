import Foundation
import HangarCore
import Testing

@testable import HangarWorker

@Suite struct ArtifactCollectorTests {
    private static func make(_ path: String, _ contents: String = "x") throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func zipEntries(_ url: URL) async throws -> [String] {
        let outcome = try await LiveProcessRunner().run(
            ProcessCommand(executable: "/usr/bin/zipinfo", arguments: ["-1", url.path]), onLine: { _ in })
        #expect(outcome.exitCode == 0)
        return outcome.output.split(separator: "\n").map(String.init).sorted()
    }

    /// Uses the real `ditto`.
    @Test func namesAndZips() async throws {
        let directory = NSTemporaryDirectory() + "hangar-artifacts-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let layout = WorkspaceLayout(dataDirectory: directory, appSlug: "demo", jobID: UUID())
        let archive = layout.archive(scheme: "Demo")
        try Self.make(archive + "/dSYMs/Demo.app.dSYM/Contents/Info.plist")
        try Self.make(layout.resultBundle + "/Info.plist")
        try Self.make(layout.export + "/Demo.ipa", "ipa")
        try Self.make(layout.export + "/Demo.app/Contents/Info.plist")
        try Self.make(layout.export + "/ExportOptions.plist", "options")
        try Self.make(layout.export + "/DistributionSummary.plist", "summary")
        try Self.make(layout.export + "/Packaging.log")

        let lines = LineSink()
        let collection = try await ArtifactCollector(runner: LiveProcessRunner())
            .collect(layout: layout, scheme: "Demo", log: lines.append)
        let collected = collection.artifacts
        #expect(collection.failures.isEmpty)

        #expect(
            collected.map(\.name) == [
                "Demo-dSYMs.zip", "Demo.xcresult.zip", "Demo.app.zip", "Demo.ipa", "ExportOptions.plist",
                "DistributionSummary.plist",
            ])
        let urls = Dictionary(uniqueKeysWithValues: collected.map { ($0.name, $0.url) })
        #expect(try await Self.zipEntries(urls["Demo-dSYMs.zip"]!).contains("dSYMs/Demo.app.dSYM/Contents/Info.plist"))
        #expect(try await Self.zipEntries(urls["Demo.xcresult.zip"]!).contains("result.xcresult/Info.plist"))
        #expect(try await Self.zipEntries(urls["Demo.app.zip"]!).contains("Demo.app/Contents/Info.plist"))
        #expect(try String(contentsOf: urls["Demo.ipa"]!, encoding: .utf8) == "ipa")
        #expect(try String(contentsOf: urls["DistributionSummary.plist"]!, encoding: .utf8) == "summary")
    }

    /// The failed snapshots of a test run, so the build page shows which ones differ.
    @Test func failedSnapshotsAreZippedOnlyWhenThereAreAny() async throws {
        let directory = NSTemporaryDirectory() + "hangar-artifacts-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let layout = WorkspaceLayout(dataDirectory: directory, appSlug: "demo", jobID: UUID())
        try Self.make(layout.resultBundle + "/Info.plist")
        try FileManager.default.createDirectory(atPath: layout.snapshotArtifacts, withIntermediateDirectories: true)
        let collector = ArtifactCollector(runner: LiveProcessRunner())

        let none = try await collector.collect(layout: layout, scheme: "Demo", log: { _ in })
        #expect(none.artifacts.map(\.name) == ["Demo.xcresult.zip"])

        try Self.make(layout.snapshotArtifacts + "/CellTests/cell_dark.png", "png")
        let some = try await collector.collect(layout: layout, scheme: "Demo", log: { _ in })
        #expect(some.artifacts.map(\.name) == ["Demo.xcresult.zip", "Demo-snapshot-failures.zip"])
        let zip = try #require(some.artifacts.last?.url)
        #expect(try await Self.zipEntries(zip).contains("snapshot-artifacts/CellTests/cell_dark.png"))
    }

    @Test func missingPiecesAreSkipped() async throws {
        let directory = NSTemporaryDirectory() + "hangar-artifacts-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let layout = WorkspaceLayout(dataDirectory: directory, appSlug: "demo", jobID: UUID())
        try Self.make(layout.resultBundle + "/Info.plist")
        let runner = RecordingProcessRunner()

        let collected = try await ArtifactCollector(runner: runner).collect(layout: layout, scheme: "Demo", log: { _ in })

        #expect(collected.artifacts.map(\.name) == ["Demo.xcresult.zip"])
        #expect(runner.commands.map(\.executable) == ["/usr/bin/ditto"])
        #expect(runner.commands.first?.arguments.prefix(3) == ["-c", "-k", "--keepParent"])
    }

    @Test func aFailedZipDoesNotStopTheRest() async throws {
        let directory = NSTemporaryDirectory() + "hangar-artifacts-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let layout = WorkspaceLayout(dataDirectory: directory, appSlug: "demo", jobID: UUID())
        try Self.make(layout.archive(scheme: "Demo") + "/dSYMs/Demo.app.dSYM/Contents/Info.plist")
        try Self.make(layout.resultBundle + "/Info.plist")
        let runner = RecordingProcessRunner()
        runner.script({ $0.arguments.contains { $0.hasSuffix("/dSYMs") } }, lines: ["ditto: No space left"], exitCode: 1)
        let lines = LineSink()

        let collection = try await ArtifactCollector(runner: runner).collect(layout: layout, scheme: "Demo", log: lines.append)

        #expect(collection.artifacts.map(\.name) == ["Demo.xcresult.zip"])
        #expect(collection.failures == ["ditto exited with status 1 while zipping Demo-dSYMs.zip"])
        #expect(lines.all.contains("error: ditto exited with status 1 while zipping Demo-dSYMs.zip"))
    }
}
