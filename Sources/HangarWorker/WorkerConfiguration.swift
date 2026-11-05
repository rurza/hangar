import Foundation
import HangarCore

public struct WorkerConfiguration: Codable, Equatable, Sendable {
    public var serverURL: URL
    public var token: String
    public var maxConcurrentJobs: Int
    /// Where the configuration lives (by default `~/Library/Application Support/Hangar/worker`).
    public var dataDirectory: String
    /// Where checkouts, DerivedData, job directories and each job's `TMPDIR` go. Nil: `defaultWorkDirectory`.
    public var workDirectory: String?

    public init(
        serverURL: URL, token: String, maxConcurrentJobs: Int = 1, dataDirectory: String, workDirectory: String? = nil
    ) {
        self.serverURL = serverURL
        self.token = token
        self.maxConcurrentJobs = maxConcurrentJobs
        self.dataDirectory = dataDirectory
        self.workDirectory = workDirectory
    }

    /// The work directory in use: the configured one, else `defaultWorkDirectory(for:home:)`.
    public var resolvedWorkDirectory: String {
        if let workDirectory, !workDirectory.isEmpty { return Self.standardized(workDirectory) }
        return Self.defaultWorkDirectory(for: dataDirectory, home: NSHomeDirectory())
    }

    /// The data directory itself when its path has no whitespace. Otherwise a path without spaces under
    /// `~/.hangar`: `~/.hangar/<name>` for the usual `~/Library/Application Support/Hangar/<name>`, and
    /// `~/.hangar/work-<hash>` for anything else. Projects written for Xcode Cloud expect a workspace path without
    /// spaces (`/Volumes/workspace/repository`): `cd $CI_PRIMARY_REPOSITORY_PATH` unquoted breaks on
    /// "Application Support".
    public static func defaultWorkDirectory(for dataDirectory: String, home: String) -> String {
        let data = standardized(dataDirectory)
        guard data.contains(where: \.isWhitespace) else { return data }
        let home = standardized(home)
        let support = home + "/Library/Application Support/Hangar/"
        var name: String
        if data.hasPrefix(support), !data.dropFirst(support.count).contains("/"), !data.dropFirst(support.count).isEmpty {
            name = String(data.dropFirst(support.count))
        } else {
            name = "work-" + String(SHA256File.hex(of: Data(data.utf8)).prefix(8))
        }
        name = String(name.map { $0.isWhitespace ? "-" : $0 })
        return home + "/.hangar/" + name
    }

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try container.decode(URL.self, forKey: .serverURL)
        token = try container.decode(String.self, forKey: .token)
        maxConcurrentJobs = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentJobs) ?? 1
        dataDirectory = try container.decode(String.self, forKey: .dataDirectory)
        workDirectory = try container.decodeIfPresent(String.self, forKey: .workDirectory)
    }

    public struct LoadError: Error, CustomStringConvertible, Equatable {
        public var description: String
    }

    public static func load(from path: String) throws -> WorkerConfiguration {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LoadError(description: "Worker configuration not found or unreadable at \(path)")
        }
        do {
            return try JSONCoding.decoder.decode(WorkerConfiguration.self, from: data)
        } catch {
            throw LoadError(description: "Invalid worker configuration at \(path): \(error)")
        }
    }
}

extension WorkerConfiguration {
    /// Writes the configuration as JSON. The file holds the machine's token, so it is created with mode 0600 and its
    /// directory with 0700; an existing file is replaced in place and its mode corrected.
    public func write(to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONCoding.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SecretsError.io(path: path, errno: errno) }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw SecretsError.io(path: path, errno: errno) }
        var offset = 0
        try data.withUnsafeBytes { buffer in
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
