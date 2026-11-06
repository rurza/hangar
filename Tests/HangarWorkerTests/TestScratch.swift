import Foundation

/// Where tests put their temporary directories: one folder per test process, removed when the process exits, so a
/// fixture never has to clean up after itself. A folder left by a process that crashed goes on the next run.
enum TestScratch {
    private static let prefix = "hangar-tests-"

    static let root: URL = {
        let temporary = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        where name.hasPrefix(prefix) {
            // A process that no longer exists left it.
            if let pid = Int32(name.dropFirst(prefix.count)), kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
            }
        }
        let root = temporary.appendingPathComponent(prefix + "\(getpid())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestScratch.root) }
        return root
    }()

    /// A new, not yet created directory: `<root>/<name>-<UUID>`.
    static func directory(_ name: String) -> URL {
        root.appendingPathComponent("\(name)-\(UUID().uuidString)")
    }
}
