import Foundation
import Testing

@testable import HangarWorker

@Suite struct SecretsMaterializerTests {
    private static func permissions(_ path: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    @Test func filesAre0600AndWipedToZeroThenRemoved() throws {
        let root = NSTemporaryDirectory() + "hangar-secrets-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let directory = root + "/job/secrets"
        let materializer = SecretsMaterializer(directory: directory)
        let key = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49\n-----END PRIVATE KEY-----\n"
        try materializer.write([(path: directory + "/HANGAR_ASC_KEY_PATH", contents: key), (path: directory + "/CERT", contents: "abc")])

        #expect(try Self.permissions(directory) == 0o700)
        #expect(try Self.permissions(directory + "/HANGAR_ASC_KEY_PATH") == 0o600)
        #expect(try Self.permissions(directory + "/CERT") == 0o600)
        #expect(try String(contentsOfFile: directory + "/HANGAR_ASC_KEY_PATH", encoding: .utf8) == key)

        // A second name for the same inode shows what wipe() left in the file's blocks.
        let probe = root + "/probe"
        #expect(link(directory + "/HANGAR_ASC_KEY_PATH", probe) == 0)

        try materializer.wipe()

        #expect(!FileManager.default.fileExists(atPath: directory))
        let wiped = try Data(contentsOf: URL(fileURLWithPath: probe))
        #expect(wiped.count == key.utf8.count)
        #expect(wiped.allSatisfy { $0 == 0 })
        // Wiping again (nothing left) is fine.
        try materializer.wipe()
    }

    @Test func refusesFilesOutsideItsDirectoryAndASymlinkedDirectory() throws {
        let root = NSTemporaryDirectory() + "hangar-secrets-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let materializer = SecretsMaterializer(directory: root + "/secrets")
        #expect(throws: SecretsError.self) { try materializer.write([(path: root + "/elsewhere", contents: "x")]) }
        #expect(throws: SecretsError.self) {
            try materializer.write([(path: root + "/secrets/../elsewhere", contents: "x")])
        }
        #expect(!FileManager.default.fileExists(atPath: root + "/elsewhere"))

        let target = root + "/target"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try "keep".write(toFile: target + "/file", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/linked", withDestinationPath: target)
        #expect(throws: SecretsError.self) { try SecretsMaterializer(directory: root + "/linked").wipe() }
        #expect(try String(contentsOfFile: target + "/file", encoding: .utf8) == "keep")
    }
}
