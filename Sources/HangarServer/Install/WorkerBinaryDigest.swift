import Foundation
import HangarCore
import Synchronization

/// SHA-256 of the `hangar-worker` this server hands out, remembered until the file's size or modification time
/// changes. Heartbeats compare it with the hash the worker reports.
enum WorkerBinaryDigest {
    private struct Cache {
        var path: String
        var modified: TimeInterval
        var size: Int
        var hex: String
    }

    private static let cache = Mutex<Cache?>(nil)

    static func current(at path: String?) -> String? {
        guard let path,
            let values = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (values[.size] as? NSNumber)?.intValue, size > 0,
            let modified = (values[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return nil }
        if let hit = cache.withLock({ $0 }), hit.path == path, hit.modified == modified, hit.size == size {
            return hit.hex
        }
        guard let hex = SHA256File.hex(of: URL(fileURLWithPath: path)) else { return nil }
        cache.withLock { $0 = Cache(path: path, modified: modified, size: size, hex: hex) }
        return hex
    }
}
