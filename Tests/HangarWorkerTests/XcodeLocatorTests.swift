import Foundation
import HangarCore
import Testing

@testable import HangarWorker

@Suite struct XcodeLocatorTests {
    static func makeXcode(in directory: URL, name: String, version: String, build: String) throws {
        let contents = directory.appendingPathComponent("\(name)/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleShortVersionString": version, "ProductBuildVersion": build]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("version.plist"))
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func readsVersionPlists() async throws {
        let directory = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.makeXcode(in: directory, name: "Xcode.app", version: "27.2", build: "27C100")
        try Self.makeXcode(in: directory, name: "Xcode-26.4.app", version: "26.4", build: "26E50")
        try Self.makeXcode(in: directory, name: "Xcode-27.10.app", version: "27.10", build: "27D1")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Safari.app"), withIntermediateDirectories: true)

        let locator = XcodeLocator(
            runner: RecordingProcessRunner(), applicationsDirectory: directory.path)
        let found = try await locator.installed()

        #expect(
            found == [
                InstalledXcode(version: "27.10", build: "27D1", path: directory.path + "/Xcode-27.10.app"),
                InstalledXcode(version: "27.2", build: "27C100", path: directory.path + "/Xcode.app"),
                InstalledXcode(version: "26.4", build: "26E50", path: directory.path + "/Xcode-26.4.app"),
            ])
    }

    @Test func includesSelectedXcodeOutsideApplicationsOnceOnly() async throws {
        let directory = try Self.tempDirectory()
        let elsewhere = try Self.tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        try Self.makeXcode(in: directory, name: "Xcode.app", version: "27.2", build: "27C100")
        try Self.makeXcode(in: elsewhere, name: "Xcode-beta.app", version: "28.0", build: "28A1")

        let runner = RecordingProcessRunner()
        runner.script({ $0.arguments == ["-p"] }, lines: [elsewhere.path + "/Xcode-beta.app/Contents/Developer"])
        let locator = XcodeLocator(runner: runner, applicationsDirectory: directory.path)
        #expect(try await locator.installed().map(\.version) == ["28.0", "27.2"])

        // Selected Xcode that is also in the scanned directory is not listed twice.
        let runner2 = RecordingProcessRunner()
        runner2.script({ $0.arguments == ["-p"] }, lines: [directory.path + "/Xcode.app/Contents/Developer"])
        let again = XcodeLocator(runner: runner2, applicationsDirectory: directory.path)
        #expect(try await again.installed().count == 1)
    }

    @Test func commandLineToolsSelectionIsIgnored() async throws {
        let directory = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingProcessRunner()
        runner.script({ $0.arguments == ["-p"] }, lines: ["/Library/Developer/CommandLineTools"])
        let locator = XcodeLocator(runner: runner, applicationsDirectory: directory.path)
        #expect(try await locator.installed().isEmpty)
    }
}
