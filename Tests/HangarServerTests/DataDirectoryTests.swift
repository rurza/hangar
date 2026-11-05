import Foundation
import Testing

@testable import HangarServer

/// The data directory holds the master key, the database, logs and signed builds: only its owner may enter it.
@Suite struct DataDirectoryTests {
    private static func mode(_ path: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hangar-data-\(UUID().uuidString)")
    }

    @Test func aNewDataDirectoryIsOwnerOnly() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("server").path
        try ServerConfiguration.prepareDataDirectory(at: path)
        #expect(try Self.mode(path) == 0o700)
    }

    @Test func anExistingOpenDataDirectoryIsTightened() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try ServerConfiguration.prepareDataDirectory(at: root.path)
        #expect(try Self.mode(root.path) == 0o700)
    }
}
