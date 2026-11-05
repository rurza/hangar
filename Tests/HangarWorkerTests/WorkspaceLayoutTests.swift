import Foundation
import Testing
@testable import HangarWorker

@Suite struct WorkspaceLayoutTests {
    @Test func jobTemporaryDirectoryLivesUnderTheGivenRootByJobID() {
        let id = UUID()
        let layout = WorkspaceLayout(
            dataDirectory: "/data", appSlug: "demo", jobID: id, temporaryRoot: "/var/folders/x/T/hangar-jobs")
        #expect(layout.temporary == "/var/folders/x/T/hangar-jobs/" + id.uuidString)
        #expect(layout.temporaryRoot == "/var/folders/x/T/hangar-jobs")
    }

    @Test func defaultTemporaryRootIsTheWorkDirectorysOwn() {
        let id = UUID()
        let layout = WorkspaceLayout(dataDirectory: "/Users/x/.hangar/worker", appSlug: "demo", jobID: id)
        #expect(layout.temporaryRoot == "/Users/x/.hangar/worker/tmp")
        #expect(layout.temporary == "/Users/x/.hangar/worker/tmp/" + id.uuidString)
        #expect(!layout.temporary.hasPrefix(layout.jobDirectory))
    }
}

@Suite struct WorkDirectoryMigrationTests {
    static func makeRoot() throws -> String {
        let root = NSTemporaryDirectory() + "hangar-migrate-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    static func write(_ path: String, _ text: String = "x") throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func movesTheWholeWorkspacesFolderWhenTheWorkDirectoryHasNone() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let data = root + "/Application Support/worker", work = root + "/work"
        try Self.write(data + "/workspaces/legilo/repository/.git/HEAD", "ref")
        try Self.write(data + "/workspaces/legilo/DerivedData/SourcePackages/repositories/x-1/HEAD")
        try Self.write(data + "/workspaces/legilo/DerivedData/SourcePackages/checkouts/x/Package.swift")
        try Self.write(data + "/workspaces/legilo/DerivedData/SourcePackages/artifacts/x/X.artifactbundle/info.json")
        try Self.write(data + "/workspaces/legilo/DerivedData/SourcePackages/workspace-state.json", data)
        try Self.write(data + "/workspaces/legilo/DerivedData/Build/Intermediates.noindex/XCBuildData/PIFCache/t-json", data)

        let lines = try WorkDirectoryMigration.run(from: data, to: work)

        #expect(lines == ["moved the workspaces from \(data)/workspaces to \(work)/workspaces"])
        #expect(try String(contentsOfFile: work + "/workspaces/legilo/repository/.git/HEAD", encoding: .utf8) == "ref")
        // The git mirrors survive; everything that names the old absolute path is dropped.
        let derived = work + "/workspaces/legilo/DerivedData"
        #expect(FileManager.default.fileExists(atPath: derived + "/SourcePackages/repositories/x-1/HEAD"))
        for gone in ["/SourcePackages/checkouts", "/SourcePackages/artifacts", "/SourcePackages/workspace-state.json", "/Build"] {
            #expect(!FileManager.default.fileExists(atPath: derived + gone), "\(gone) should be dropped")
        }
        #expect(!FileManager.default.fileExists(atPath: data + "/workspaces"))
        // A second run has nothing to do.
        #expect(try WorkDirectoryMigration.run(from: data, to: work).isEmpty)
    }

    @Test func movesOnlyAppsTheWorkDirectoryDoesNotHave() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let data = root + "/data", work = root + "/work"
        try Self.write(data + "/workspaces/legilo/repository/old")
        try Self.write(data + "/workspaces/batfi/repository/f")
        try Self.write(data + "/workspaces/batfi/DerivedData/SourcePackages/workspace-state.json", data)
        try Self.write(work + "/workspaces/legilo/repository/new")

        let lines = try WorkDirectoryMigration.run(from: data, to: work)

        #expect(lines == [
            "moved the workspace batfi from \(data)/workspaces to \(work)/workspaces",
            "kept \(work)/workspaces/legilo; the older \(data)/workspaces/legilo was left in place",
        ])
        #expect(FileManager.default.fileExists(atPath: work + "/workspaces/batfi/repository/f"))
        #expect(!FileManager.default.fileExists(atPath: work + "/workspaces/batfi/DerivedData/SourcePackages/workspace-state.json"))
        #expect(FileManager.default.fileExists(atPath: work + "/workspaces/legilo/repository/new"))
        #expect(FileManager.default.fileExists(atPath: data + "/workspaces/legilo/repository/old"))
    }

    @Test func nothingToDoWhenTheyAreTheSameOrThereIsNothing() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Self.write(root + "/workspaces/a/f")
        #expect(try WorkDirectoryMigration.run(from: root, to: root).isEmpty)
        #expect(try WorkDirectoryMigration.run(from: root + "/none", to: root + "/work").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root + "/work"))
    }
}
