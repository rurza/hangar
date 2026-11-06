import Foundation
import Testing

@testable import HangarCore

@Suite struct DiskUsageTests {
    private func temporaryDirectory() throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("disk-usage-\(UUID().uuidString)")
            .standardizedFileURL.path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func write(_ path: String, megabytes: Int, byte: UInt8 = 0x41) throws {
        try Data(repeating: byte, count: megabytes * 1_000_000).write(to: URL(fileURLWithPath: path))
    }

    @Test func aFileCountsItsBlocks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root + "/a", megabytes: 4)
        let bytes = DiskUsage.bytes(of: root)
        #expect(bytes >= 4_000_000 && bytes < 4_100_000)
    }

    @Test func clonesShareTheirBlocksAndCountOnce() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root + "/image", megabytes: 8)
        // An APFS clone, as an image's slots and job clones are.
        try #require(clonefile(root + "/image", root + "/clone", 0) == 0)
        let shared = DiskUsage.bytes(of: root)
        #expect(shared >= 8_000_000 && shared < 8_100_000)
        // What a clone writes is its own.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: root + "/clone"))
        try handle.write(contentsOf: Data(repeating: 0x42, count: 2_000_000))
        try handle.synchronize()
        try handle.close()
        let diverged = DiskUsage.bytes(of: root)
        #expect(diverged >= 10_000_000 && diverged < 10_100_000)
        // Either file alone still counts every block it uses.
        #expect(DiskUsage.bytes(of: root + "/image") >= 8_000_000)
        #expect(DiskUsage.bytes(of: [root + "/image", root + "/clone"]) == diverged)
    }

    @Test func holesAndLinksCountNothing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // A 1 GB sparse disk with nothing written, like a fresh disk.img.
        FileManager.default.createFile(atPath: root + "/disk.img", contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: root + "/disk.img"))
        try handle.truncate(atOffset: 1_000_000_000)
        try handle.close()
        try write(root + "/real", megabytes: 1)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/real")
        let bytes = DiskUsage.bytes(of: root)
        #expect(bytes >= 1_000_000 && bytes < 1_100_000)
        #expect(DiskUsage.bytes(of: root + "/missing") == 0)
    }

    @Test func amountsReadAsFinderShowsThem() {
        #expect(DiskUsage.text(50_712_000_000) == "51 GB")
        #expect(DiskUsage.text(1_310_000_000) == "1.3 GB")
        #expect(DiskUsage.text(120_400_000) == "120 MB")
        #expect(DiskUsage.text(0) == "0 MB")
    }
}
