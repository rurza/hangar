import Foundation

public enum SecretsError: Error, Equatable, CustomStringConvertible {
    case outsideDirectory(path: String, directory: String)
    case symlinkedDirectory(String)
    case io(path: String, errno: Int32)

    public var description: String {
        switch self {
        case .outsideDirectory(let path, let directory): "refusing to write '\(path)': not directly inside '\(directory)'"
        case .symlinkedDirectory(let directory): "refusing to wipe '\(directory)': it is a symbolic link"
        case .io(let path, let code): "\(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Puts a job's as-file variables on disk for the job's lifetime and destroys them afterwards.
public struct SecretsMaterializer: Sendable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    /// Creates the directory with mode 0700 and each file with mode 0600. Every path must name a file directly inside
    /// the directory; nothing is written unless all of them do.
    public func write(_ files: [(path: String, contents: String)]) throws {
        for file in files where (file.path as NSString).deletingLastPathComponent != directory
            || URL(fileURLWithPath: file.path).standardizedFileURL.path != file.path
        {
            throw SecretsError.outsideDirectory(path: file.path, directory: directory)
        }
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // An existing directory keeps its mode on createDirectory, and the requested mode is subject to the umask.
        guard chmod(directory, 0o700) == 0 else { throw SecretsError.io(path: directory, errno: errno) }
        for file in files {
            try Self.writeFile(file.path, Data(file.contents.utf8))
        }
    }

    /// Overwrites every regular file with zeros of its length, syncs it to disk, then removes the directory. Symbolic
    /// links are removed, never followed; a directory that is itself a symbolic link is refused. A missing directory
    /// is fine.
    public func wipe() throws {
        var info = stat()
        guard lstat(directory, &info) == 0 else {
            if errno == ENOENT { return }
            throw SecretsError.io(path: directory, errno: errno)
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else { throw SecretsError.symlinkedDirectory(directory) }
        try zeroFiles(in: directory)
        try FileManager.default.removeItem(atPath: directory)
    }

    private func zeroFiles(in directory: String) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: directory) {
            let path = directory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { throw SecretsError.io(path: path, errno: errno) }
            switch info.st_mode & S_IFMT {
            case S_IFREG: try Self.zero(path, length: Int(info.st_size))
            case S_IFDIR: try zeroFiles(in: path)
            default: break  // Symbolic links and the like are only unlinked, with the directory.
            }
        }
    }

    private static func writeFile(_ path: String, _ data: Data) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SecretsError.io(path: path, errno: errno) }
        defer { close(descriptor) }
        // A file left over from an earlier write keeps its old mode on open.
        guard fchmod(descriptor, 0o600) == 0 else { throw SecretsError.io(path: path, errno: errno) }
        try writeAll(descriptor, data, path: path)
    }

    private static func zero(_ path: String, length: Int) throws {
        let descriptor = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SecretsError.io(path: path, errno: errno) }
        defer { close(descriptor) }
        try writeAll(descriptor, Data(count: length), path: path)
        guard fsync(descriptor) == 0 else { throw SecretsError.io(path: path, errno: errno) }
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Foundation.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SecretsError.io(path: path, errno: errno)
                }
                offset += written
            }
        }
    }
}
