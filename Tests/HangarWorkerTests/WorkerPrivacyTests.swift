import Foundation
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

    @Test func onlyTheHangarUserInItsOwnHomeIsTheDedicatedAccount() {
        #expect(WorkerPrivacy.isDedicatedAccount(user: "hangar", home: "/Users/hangar"))
        #expect(WorkerPrivacy.isDedicatedAccount(user: "hangar", home: "/Users/hangar/"))
        #expect(!WorkerPrivacy.isDedicatedAccount(user: "adam", home: "/Users/adam"))
        #expect(!WorkerPrivacy.isDedicatedAccount(user: "hangar", home: "/Users/adam"))
        #expect(!WorkerPrivacy.isDedicatedAccount(user: "adam", home: "/Users/hangar"))
        #expect(!WorkerPrivacy.isDedicatedAccount(user: "hangar", home: "/Volumes/Shared/hangar"))
    }

    @Test func warnsOnlyWhenNotTheDedicatedAccount() throws {
        #expect(WorkerPrivacy.startupWarning(user: "hangar", home: "/Users/hangar") == nil)
        let warning = try #require(WorkerPrivacy.startupWarning(user: "adam", home: "/Users/adam"))
        #expect(warning.contains("running as adam"))
        #expect(warning.contains("hangar-worker isolate"))
    }

    @Test func lockDownSetsAnOpenDirectoryToOwnerOnly() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try WorkerPrivacy.setMode(0o755, at: home)
        try WorkerPrivacy.lockDown(home: home)
        #expect(try mode(home) == 0o700)
    }

    @Test func theDataDirectoryIsPrivateWhetherNewOrExisting() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: parent) }
        let logger = Logger(label: "test")

        let fresh = parent + "/fresh/worker"
        #expect(WorkerLoop.createPrivateDataDirectory(fresh, logger: logger))
        #expect(try mode(fresh) == 0o700)

        let existing = parent + "/existing"
        try FileManager.default.createDirectory(
            atPath: existing, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try WorkerPrivacy.setMode(0o755, at: existing)
        let cache = existing + "/workspaces"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        try WorkerPrivacy.setMode(0o755, at: cache)
        #expect(WorkerLoop.createPrivateDataDirectory(existing, logger: logger))
        #expect(try mode(existing) == 0o700)
        #expect(try mode(cache) == 0o755, "the cache inside is not walked")
    }
}
