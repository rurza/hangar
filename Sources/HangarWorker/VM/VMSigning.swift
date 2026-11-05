import Foundation
import HangarCore

/// The worker's one Apple Development identity for VM builds (VM builds design, *Signing*). It is kept on the host,
/// as a `.p12` and its password in two 0600 files next to the worker's configuration, and goes into each job's VM.
/// Not one per VM or per job: Apple limits development certificates per team, and an `-allowProvisioningUpdates`
/// archive in a fresh VM without an identity would create a new certificate every time.
public struct VMIdentityStore: Sendable, Equatable {
    public static let fileName = "vm-identity.p12"
    public static let passwordFileName = "vm-identity-password"

    public var file: String
    public var passwordFile: String

    public init(dataDirectory: String) {
        file = dataDirectory + "/" + Self.fileName
        passwordFile = dataDirectory + "/" + Self.passwordFileName
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: file) && FileManager.default.fileExists(atPath: passwordFile) }

    /// Stores a `.p12` and its password, each 0600.
    public func save(p12: Data, password: SensitiveText) throws {
        try SecretFile.write(p12, to: file)
        try SecretFile.write(Data(password.value.utf8), to: passwordFile)
    }

    /// Nil when there is none.
    public func load() throws -> GuestIdentity? {
        guard exists else { return nil }
        guard let p12 = FileManager.default.contents(atPath: file),
            let password = try? String(contentsOfFile: passwordFile, encoding: .utf8)
        else { throw VMStorageError.unreadable(file) }
        return GuestIdentity(p12: p12, password: password.trimmingCharacters(in: .newlines))
    }

    public func remove() {
        try? FileManager.default.removeItem(atPath: file)
        try? FileManager.default.removeItem(atPath: passwordFile)
    }

    /// Exports every identity in the CI keychain (the Apple Development identity the host's archives created) as a
    /// `.p12` with a generated password, through `security -i` so the password stays off the command line.
    public func exportFromKeychain(
        _ keychain: CIKeychain, runner: any ProcessRunner, password: SensitiveText = RandomPasswordGenerator().generate()
    ) async throws {
        try await keychain.prepare(runner: runner)
        let staging = (file as NSString).deletingLastPathComponent + "/.vm-identity-export-\(UUID().uuidString).p12"
        defer { try? FileManager.default.removeItem(atPath: staging) }
        let input = SensitiveText(
            "export -k \(Self.quoted(keychain.path)) -t identities -f pkcs12 -P \(Self.quoted(password.value)) -o \(Self.quoted(staging))\n")
        let outcome = try await runner.run(
            ProcessCommand(executable: "/usr/bin/security", arguments: ["-i"], environment: CIKeychain.environment, standardInput: input),
            onLine: { _ in })
        guard outcome.exitCode == 0, let data = FileManager.default.contents(atPath: staging), !data.isEmpty else {
            throw CIKeychainError.failed("security export", exitCode: outcome.exitCode)
        }
        try save(p12: data, password: password)
    }

    /// A double-quoted word for `security -i`, which splits on spaces and honours `"` and `\`.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// The identity as it travels to a guest, inside the job bundle on the SSH session's standard input.
public struct GuestIdentity: Codable, Equatable, Sendable, CustomStringConvertible {
    public var p12: Data
    public var password: String

    public init(p12: Data, password: String) {
        self.p12 = p12
        self.password = password
    }

    public var description: String { "<identity>" }
}

/// The job's keychain inside the guest: created with a random password, the identity imported, codesign allowed, made
/// the default. It lives on the clone and goes with it; the `.p12` file is deleted right after the import.
public enum GuestKeychain {
    /// Creates `<directory>/job.keychain-db` and returns it as a `CIKeychain`, which the job's `JobRunner` unlocks and
    /// keeps first on the search list, as on a headless host.
    public static func install(
        _ identity: GuestIdentity?, directory: String, runner: any ProcessRunner,
        password: SensitiveText = RandomPasswordGenerator().generate()
    ) async throws -> CIKeychain {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keychain = CIKeychain(path: directory + "/job.keychain-db", passwordFile: directory + "/keychain-password")
        try SecretFile.write(Data(password.value.utf8), to: keychain.passwordFile)
        try await security("create-keychain", CIKeychain.createInput(password: password, path: keychain.path), runner: runner)
        // No auto-lock during a long archive.
        let settings = try await runner.run(
            ProcessCommand(executable: "/usr/bin/security", arguments: ["set-keychain-settings", keychain.path], environment: CIKeychain.environment),
            onLine: { _ in })
        guard settings.exitCode == 0 else { throw CIKeychainError.failed("security set-keychain-settings", exitCode: settings.exitCode) }
        try await keychain.prepare(runner: runner)
        if let identity {
            let p12 = directory + "/identity.p12"
            try SecretFile.write(identity.p12, to: p12)
            defer { try? FileManager.default.removeItem(atPath: p12) }
            let input = SensitiveText(
                "import \(VMIdentityStore.quoted(p12)) -k \(VMIdentityStore.quoted(keychain.path)) -f pkcs12 -P \(VMIdentityStore.quoted(identity.password)) -T /usr/bin/codesign -T /usr/bin/security\n")
            try await security("security import", input, runner: runner)
            try await keychain.allowCodesign(runner: runner)
        }
        return keychain
    }

    private static func security(_ what: String, _ input: SensitiveText, runner: any ProcessRunner) async throws {
        let outcome = try await runner.run(
            ProcessCommand(executable: "/usr/bin/security", arguments: ["-i"], environment: CIKeychain.environment, standardInput: input),
            onLine: { _ in })
        guard outcome.exitCode == 0 else { throw CIKeychainError.failed(what, exitCode: outcome.exitCode) }
    }
}

/// A file only its owner reads: created 0600 without following a symlink, replaced in place.
enum SecretFile {
    static func write(_ data: Data, to path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SecretsError.io(path: path, errno: errno) }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw SecretsError.io(path: path, errno: errno) }
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
