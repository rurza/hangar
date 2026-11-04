import CryptoKit
import Foundation

public enum MasterKey {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Reads the 32-byte key at `path`, creating it (0600, atomically, with its parent directory) on first use.
    public static func loadOrCreate(at path: String) throws -> SymmetricKey {
        let fileManager = FileManager.default
        if let existing = fileManager.contents(atPath: path) { return try key(from: existing, path: path) }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let temporary = directory.appendingPathComponent(".master.key.\(UUID().uuidString)").path
        guard fileManager.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure(description: "Could not write the master key at \(path)")
        }
        defer { try? fileManager.removeItem(atPath: temporary) }
        // link(2) fails when another process created the key first; then that one wins.
        if link(temporary, path) != 0 {
            guard let existing = fileManager.contents(atPath: path) else {
                throw Failure(description: "Could not create the master key at \(path)")
            }
            return try Self.key(from: existing, path: path)
        }
        return key
    }

    private static func key(from data: Data, path: String) throws -> SymmetricKey {
        guard data.count == 32 else { throw Failure(description: "The master key at \(path) is not 32 bytes") }
        return SymmetricKey(data: data)
    }
}
