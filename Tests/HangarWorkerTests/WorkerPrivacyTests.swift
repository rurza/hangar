import Foundation
import HangarCore
import Logging
import Testing

@testable import HangarWorker

@Suite struct WorkerPrivacyTests {
    private func temporaryDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "hangar-privacy-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    @Test func localBuildsWarnThatABuildCanReadTheOwnersFiles() throws {
        let warning = try #require(WorkerPrivacy.startupWarning(
            user: "adam", setupCommand: "sudo /Users/adam/.local/bin/hangar-worker vm setup"))
        #expect(warning.contains("running as adam"))
        #expect(warning.hasSuffix("sudo /Users/adam/.local/bin/hangar-worker vm setup"))
        // With VM builds on, builds cannot read adam's files.
        #expect(WorkerPrivacy.startupWarning(user: "adam", vmBuilds: true) == nil)
    }

    @Test func generatedPasswordsAreLongGroupedAndUnambiguous() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let password = RandomPasswordGenerator().generate().value
            #expect(password.wholeMatch(of: /[a-hjkmnp-z2-9]{4}(-[a-hjkmnp-z2-9]{4}){4}/) != nil)
            seen.insert(password)
        }
        #expect(seen.count == 200)
        #expect(RandomPasswordGenerator.alphabet.count == 31)
    }

    @Test func theDataDirectoryIsPrivateWhetherNewOrExisting() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: parent) }
        let logger = Logger(label: "test")

        let fresh = parent + "/fresh/worker"
        #expect(WorkerLoop.createPrivateDirectory(fresh, logger: logger))
        #expect(try mode(fresh) == 0o700)

        let existing = parent + "/existing"
        try FileManager.default.createDirectory(
            atPath: existing, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try WorkerPrivacy.setMode(0o755, at: existing)
        let cache = existing + "/workspaces"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        try WorkerPrivacy.setMode(0o755, at: cache)
        #expect(WorkerLoop.createPrivateDirectory(existing, logger: logger))
        #expect(try mode(existing) == 0o700)
        #expect(try mode(cache) == 0o755, "the cache inside is not walked")
    }
}
