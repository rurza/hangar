import Foundation
import HangarCore
import Synchronization

/// SSH from the host into a guest (VM builds design, *Control channel*, first slice). Host to guest only: the network
/// filter lets the host open connections into the guest subnet and nothing the other way.
///
/// The host's key (`VMStorage.privateKey`) logs in; the guest's host keys are those recorded in the image's
/// `known_hosts` under one alias, since every clone of an image has the same ones. Remote commands are strings for
/// the guest's shell: build them with `GuestSSH.quote`.
public struct GuestSSH: Sendable {
    public enum HostKeys: Sendable, Equatable {
        /// Pinned: the image's recorded keys must match.
        case pinned(knownHosts: String)
        /// Recorded on first contact into `knownHosts` (while building an image).
        case record(knownHosts: String)
    }

    public static let hostKeyAlias = "hangar-guest"

    public var runner: any ProcessRunner
    public var privateKey: String
    public var hostKeys: HostKeys
    /// Set for the first login into a vanilla image, whose `admin` has the published password `admin` and no key yet:
    /// an askpass script that prints it. Never a real secret.
    public var askpassScript: String?

    public init(runner: any ProcessRunner, privateKey: String, hostKeys: HostKeys, askpassScript: String? = nil) {
        self.runner = runner
        self.privateKey = privateKey
        self.hostKeys = hostKeys
        self.askpassScript = askpassScript
    }

    /// The `ssh` arguments before the destination: no agent, no config file, no password prompt (unless askpass),
    /// a dead connection noticed within 45 s.
    public func options(connectTimeout: Int = 5) -> [String] {
        var options = [
            "-F", "/dev/null", "-o", "IdentitiesOnly=yes", "-i", privateKey, "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "LogLevel=ERROR",
            "-o", "HostKeyAlias=\(Self.hostKeyAlias)", "-o", "ExitOnForwardFailure=yes",
        ]
        switch hostKeys {
        case .pinned(let file): options += ["-o", "UserKnownHostsFile=\(file)", "-o", "StrictHostKeyChecking=yes"]
        case .record(let file): options += ["-o", "UserKnownHostsFile=\(file)", "-o", "StrictHostKeyChecking=accept-new"]
        }
        if askpassScript != nil {
            options += ["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
        } else {
            options += ["-o", "BatchMode=yes", "-o", "PasswordAuthentication=no"]
        }
        return options
    }

    public var environment: [String: String] {
        var environment = CIEnvironment.identityEnvironment(from: ProcessInfo.processInfo.environment)
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        if let askpassScript {
            environment["SSH_ASKPASS"] = askpassScript
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = ":0"
        }
        return environment
    }

    /// `ssh … user@host -- remote`.
    public func command(
        user: String, host: String, _ remote: String, extraOptions: [String] = [], input: SensitiveText? = nil
    ) -> ProcessCommand {
        ProcessCommand(
            executable: "/usr/bin/ssh", arguments: options() + extraOptions + ["\(user)@\(host)", "--", remote],
            environment: environment, standardInput: input)
    }

    /// Runs `remote` in the guest; the outcome's exit status is the remote command's (255: ssh itself failed).
    @discardableResult
    public func run(
        user: String, host: String, _ remote: String, input: SensitiveText? = nil,
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ProcessOutcome {
        try await runner.run(command(user: user, host: host, remote, input: input), onLine: onLine)
    }

    /// Runs `remote` and throws `GuestCommandError` unless it exits 0. `what` names it in the error.
    public func require(
        _ what: String, user: String, host: String, _ remote: String, input: SensitiveText? = nil,
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        let outcome = try await run(user: user, host: host, remote, input: input, onLine: onLine)
        guard outcome.exitCode == 0 else {
            throw GuestCommandError(what: what, exitCode: outcome.exitCode, output: outcome.output)
        }
    }

    /// Streams a local file into `remotePath` in the guest (`ssh … 'cat > path' < file`), through `/bin/sh` so the
    /// file need not fit a pipe buffer. The paths are not secret.
    public func copy(file: String, user: String, host: String, to remotePath: String, mode: String = "0755") async throws {
        let ssh = (["/usr/bin/ssh"] + options() + ["\(user)@\(host)", "--"]).map(Self.quote).joined(separator: " ")
        let remote = "umask 077 && cat > \(Self.quote(remotePath)) && chmod \(mode) \(Self.quote(remotePath))"
        let script = "\(ssh) \(Self.quote(remote)) < \(Self.quote(file))"
        let outcome = try await runner.run(
            ProcessCommand(executable: "/bin/sh", arguments: ["-c", script], environment: environment), onLine: { _ in })
        guard outcome.exitCode == 0 else {
            throw GuestCommandError(what: "copy \((file as NSString).lastPathComponent) into the VM", exitCode: outcome.exitCode, output: outcome.output)
        }
    }

    /// Copies `remotePath` (a file or a directory in the guest) to `localPath` on the host, as `tar` over SSH, and
    /// returns false when the guest has no such path. What arrives is the guest's, so it is unpacked into a staging
    /// directory first (bsdtar refuses absolute and `..` paths by default) and checked by `GuestCopy.check` before it
    /// is moved into place: no link may point outside it and nothing but files, directories and links may be in it.
    public func fetch(user: String, host: String, remotePath: String, to localPath: String) async throws -> Bool {
        let exists = try await run(user: user, host: host, "test -e \(Self.quote(remotePath))")
        if exists.exitCode == 1 { return false }
        guard exists.exitCode == 0 else {
            throw GuestCommandError(what: "look for \(remotePath) in the VM", exitCode: exists.exitCode, output: exists.output)
        }
        let parent = (localPath as NSString).deletingLastPathComponent
        let staging = parent + "/.hangar-fetch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: staging) }
        let name = (remotePath as NSString).lastPathComponent
        let remoteParent = (remotePath as NSString).deletingLastPathComponent
        let ssh = (["/usr/bin/ssh"] + options() + ["\(user)@\(host)", "--"]).map(Self.quote).joined(separator: " ")
        let remote = "tar -C \(Self.quote(remoteParent)) -cf - \(Self.quote(name))"
        let script = "set -o pipefail; \(ssh) \(Self.quote(remote)) | /usr/bin/tar -xf - --no-same-owner -C \(Self.quote(staging))"
        let outcome = try await runner.run(
            ProcessCommand(executable: "/bin/sh", arguments: ["-c", script], environment: environment), onLine: { _ in })
        guard outcome.exitCode == 0 else {
            throw GuestCommandError(what: "copy \(name) out of the VM", exitCode: outcome.exitCode, output: outcome.output)
        }
        let copied = staging + "/" + name
        try GuestCopy.check(copied)
        try? FileManager.default.removeItem(atPath: localPath)
        try FileManager.default.moveItem(atPath: copied, toPath: localPath)
        return true
    }

    /// Single-quotes `text` for a POSIX shell.
    public static func quote(_ text: String) -> String {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-=:@%+,".contains($0)) }) else {
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return text
    }
}

public struct GuestCommandError: Error, Equatable, CustomStringConvertible {
    public var what: String
    public var exitCode: Int32
    /// The last lines, for the error; never includes the command's standard input.
    public var output: String

    public init(what: String, exitCode: Int32, output: String) {
        self.what = what
        self.exitCode = exitCode
        self.output = output
    }

    public var description: String {
        let tail = output.split(separator: "\n").suffix(5).joined(separator: " | ")
        let reason = exitCode == 255 ? "ssh could not reach the VM or the command was killed" : "exited with status \(exitCode)"
        return tail.isEmpty ? "\(what): \(reason)" : "\(what): \(reason): \(tail)"
    }
}

/// The host's key into its guests: ed25519, made once in `VMStorage.keys`.
public enum GuestKeys {
    public static func ensure(storage: VMStorage, runner: any ProcessRunner) async throws {
        try storage.create()
        guard !FileManager.default.fileExists(atPath: storage.privateKey) else { return }
        let outcome = try await runner.run(
            ProcessCommand(
                executable: "/usr/bin/ssh-keygen",
                arguments: ["-q", "-t", "ed25519", "-N", "", "-C", "hangar-worker@\(JobRunner.computerName)", "-f", storage.privateKey],
                environment: ["PATH": "/usr/bin:/bin"]),
            onLine: { _ in })
        guard outcome.exitCode == 0 else {
            throw GuestCommandError(what: "ssh-keygen", exitCode: outcome.exitCode, output: outcome.output)
        }
    }

    public static func publicKey(storage: VMStorage) throws -> String {
        guard let text = try? String(contentsOfFile: storage.publicKey, encoding: .utf8) else {
            throw VMStorageError.unreadable(storage.publicKey)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the host checks in a copy out of a guest before anything of its own reads it (`GuestSSH.fetch`).
public enum GuestCopy {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case linkLeaves(String, target: String)
        case notAFile(String)

        public var description: String {
            switch self {
            case .missing(let path): "\(path) did not arrive from the VM"
            case .linkLeaves(let path, let target): "\(path) in the VM's copy is a link to \(target), outside it"
            case .notAFile(let path): "\(path) in the VM's copy is neither a file, a directory nor a link"
            }
        }
    }

    /// Throws when `root` holds a symbolic link whose target is absolute or leads outside `root`, or anything but
    /// regular files, directories and links (a FIFO or a device would make a reader hang or worse).
    public static func check(_ root: String) throws {
        let fileManager = FileManager.default
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        guard let type = try? fileManager.attributesOfItem(atPath: root)[.type] as? FileAttributeType else {
            throw Problem.missing((root as NSString).lastPathComponent)
        }
        var items: [(relative: String, type: FileAttributeType)] = [("", type)]
        if type == .typeDirectory, let enumerator = fileManager.enumerator(atPath: root) {
            while let relative = enumerator.nextObject() as? String {
                let itemType = enumerator.fileAttributes?[.type] as? FileAttributeType ?? .typeUnknown
                items.append((relative, itemType))
            }
        }
        for (relative, type) in items {
            let path = relative.isEmpty ? root : root + "/" + relative
            switch type {
            case .typeRegular, .typeDirectory: continue
            case .typeSymbolicLink:
                let target = try fileManager.destinationOfSymbolicLink(atPath: path)
                let resolved = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true))
                    .standardizedFileURL.path
                guard !target.hasPrefix("/"), resolved == base || resolved.hasPrefix(base + "/") else {
                    throw Problem.linkLeaves(relative.isEmpty ? (root as NSString).lastPathComponent : relative, target: target)
                }
            default:
                throw Problem.notAFile(relative.isEmpty ? (root as NSString).lastPathComponent : relative)
            }
        }
    }
}
