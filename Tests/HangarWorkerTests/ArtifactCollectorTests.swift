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
        let collected = try await ArtifactCollector(runner: LiveProcessRunner())
            .collect(layout: layout, scheme: "Demo", log: lines.append)

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

    @Test func missingPiecesAreSkipped() async throws {
        let directory = NSTemporaryDirectory() + "hangar-artifacts-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let layout = WorkspaceLayout(dataDirectory: directory, appSlug: "demo", jobID: UUID())
        try Self.make(layout.resultBundle + "/Info.plist")
        let runner = RecordingProcessRunner()

        let collected = try await ArtifactCollector(runner: runner).collect(layout: layout, scheme: "Demo", log: { _ in })

        #expect(collected.map(\.name) == ["Demo.xcresult.zip"])
        #expect(runner.commands.map(\.executable) == ["/usr/bin/ditto"])
        #expect(runner.commands.first?.arguments.prefix(3) == ["-c", "-k", "--keepParent"])
    }
}
