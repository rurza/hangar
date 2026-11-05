import Darwin
import Foundation
import HangarCore

/// Replaces this process's `hangar-worker` with the binary its server is handing out, then re-executes so the new
/// one is what keeps running. The hash is the one the server announced on an authenticated heartbeat; the download
/// itself is the same unauthenticated `GET /install/hangar-worker` the install script uses.
public enum WorkerSelfUpdate {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case hashMismatch
        case download(Int)
        case unwritable(String)

        public var description: String {
            switch self {
            case .hashMismatch: "The downloaded hangar-worker did not match the hash the server announced."
            case .download(let status): "Downloading hangar-worker failed: HTTP \(status)."
            case .unwritable(let path): "Cannot replace hangar-worker at \(path)."
            }
        }
    }

    /// SHA-256 of the binary this process was started from. Read once: a later replacement of the file on disk does
    /// not change it, so the server can still see that this process is the old one.
    public static let executableSHA256: String? = {
        guard let url = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        return SHA256File.hex(of: url)
    }()

    /// `GET /install/hangar-worker` on `server`, which is the worker's configured origin (`http://host:8789`).
    public static func binaryURL(server: URL) -> URL? {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/install/hangar-worker"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public static func download(from server: URL, session: URLSession = .shared) async throws -> Data {
        guard let url = binaryURL(server: server) else { throw Failure.download(0) }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else { throw Failure.download(status) }
        return data
    }

    /// Writes `data` beside `executable` after checking it is exactly `sha256`. The caller renames it into place
    /// only once it is still idle, so a job that started during the download is not killed by the restart.
    public static func stage(_ data: Data, sha256: String, nextTo executable: URL) throws -> URL {
        guard SHA256File.hex(of: data) == sha256.lowercased() else { throw Failure.hashMismatch }
        let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: directory.path) else { throw Failure.unwritable(executable.path) }
        let staged = directory.appendingPathComponent(".hangar-worker.update")
        try data.write(to: staged, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        clearQuarantine(staged)
        return staged
    }

    /// Renames `staged` over `executable`. The running process keeps the old inode until `relaunch()`.
    public static func replace(_ executable: URL, with staged: URL) throws {
        _ = try FileManager.default.replaceItemAt(executable.resolvingSymlinksInPath(), withItemAt: staged)
    }

    /// Re-executes this process's executable with the same arguments. Returns only when `exec` fails.
    @discardableResult
    public static func relaunch() -> Bool {
        guard let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return false }
        let args = CommandLine.arguments
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: args.count + 1)
        for (index, argument) in args.enumerated() {
            argv[index] = strdup(argument)
        }
        argv[args.count] = nil
        execv(path, argv)
        for index in 0..<args.count { free(argv[index]) }
        argv.deallocate()
        return false
    }

    private static func clearQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "com.apple.quarantine", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
