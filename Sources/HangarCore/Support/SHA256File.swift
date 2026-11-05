import CryptoKit
import Foundation

/// SHA-256 of a file or a buffer, as a lowercase hex string. Workers and the server compare these to tell whether
/// the running `hangar-worker` is the binary the server would hand out.
public enum SHA256File {
    public static func hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return hex(of: data)
    }

    public static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
