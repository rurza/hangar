import CryptoKit
import Foundation
import Testing

@testable import HangarServer

@Suite struct SecretBoxTests {
    let box = SecretBox(key: SymmetricKey(size: .bits256))

    @Test func roundTripsAndDiffersPerSeal() throws {
        let first = try box.seal("hunter2")
        let second = try box.seal("hunter2")
        #expect(first != second)
        #expect(try box.open(first) == "hunter2")
        #expect(try box.open(second) == "hunter2")
    }

    @Test func rejectsTamperedCiphertext() throws {
        var sealed = try box.seal("hunter2")
        sealed[sealed.count - 1] ^= 0xFF
        #expect(throws: (any Error).self) { try box.open(sealed) }
    }

    @Test func masterKeyIsCreatedOnceWithOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("nested/master.key").path
        let first = try MasterKey.loadOrCreate(at: path)
        let second = try MasterKey.loadOrCreate(at: path)
        #expect(first == second)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}
