import Foundation
import HangarCore

/// An optional per-worker override of the server's Apple Development identity for VM builds (VM builds design,
/// *Signing*). The server's one identity (Settings › Signing) comes with each VM archive's assignment; when this worker
/// holds its own, as a `.p12` and its password in two 0600 files next to its configuration, that one goes into the
/// job's VM instead. Never one per VM or per job: Apple limits development certificates per team.
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

/// The job's keychain inside the guest (security review 2026-11-06, H1): created with a random password that stays in
/// the guest worker's memory (never in a file the build user's scripts could read), the identity imported so its
/// private key cannot be exported, codesign allowed, made the default. It lives on the clone and goes with it.
///
/// `security import -x` is ignored for a `.p12` (tested on macOS 27.2: the key exported again byte for byte), so the
/// `.p12` is split with `/usr/bin/openssl` first: the private key is imported on its own as a PKCS#1 PEM with `-x`
/// and only codesign in its access list, then the certificates. A later `security export` of the key fails with
/// "The contents of this item cannot be retrieved". Build code can still sign with it during the job, which the VM
/// design accepts; it can no longer take it away. Every intermediate file is 0600 in the 0700 directory and is
/// deleted before the job's first script runs.
public enum GuestKeychain {
    /// Creates `<directory>/job.keychain-db` and returns it as a `CIKeychain` with its password in memory, which the
    /// job's `JobRunner` unlocks and keeps first on the search list, as on a headless host.
    public static func install(
        _ identity: GuestIdentity?, directory: String, runner: any ProcessRunner,
        password: SensitiveText = RandomPasswordGenerator().generate()
    ) async throws -> CIKeychain {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keychain = CIKeychain(path: directory + "/job.keychain-db", password: password)
        try await security("create-keychain", CIKeychain.createInput(password: password, path: keychain.path), runner: runner)
        // No auto-lock during a long archive: no timeout, and a VM does not sleep.
        let settings = try await runner.run(
            ProcessCommand(executable: "/usr/bin/security", arguments: ["set-keychain-settings", keychain.path], environment: CIKeychain.environment),
            onLine: { _ in })
        guard settings.exitCode == 0 else { throw CIKeychainError.failed("security set-keychain-settings", exitCode: settings.exitCode) }
        try await keychain.prepare(runner: runner)
        if let identity {
            let p12 = directory + "/identity.p12"
            let pkcs8 = directory + "/identity-key-pkcs8.pem"
            let key = directory + "/identity-key.pem"
            let certificates = directory + "/identity-certificates.pem"
            defer { for file in [p12, pkcs8, key, certificates] { try? FileManager.default.removeItem(atPath: file) } }
            try SecretFile.write(identity.p12, to: p12)
            let passphrase = SensitiveText(identity.password + "\n")
            try await openssl(["pkcs12", "-in", p12, "-nocerts", "-nodes", "-passin", "stdin", "-out", pkcs8], input: passphrase, "read the identity's key", runner: runner)
            try await openssl(["rsa", "-in", pkcs8, "-out", key], input: nil, "convert the identity's key", runner: runner)
            try await openssl(["pkcs12", "-in", p12, "-nokeys", "-passin", "stdin", "-out", certificates], input: passphrase, "read the identity's certificates", runner: runner)
            for file in [key, certificates] where FileManager.default.fileExists(atPath: file) { chmod(file, 0o600) }
            try await security(
                "security import (key)",
                SensitiveText("import \(VMIdentityStore.quoted(key)) -k \(VMIdentityStore.quoted(keychain.path)) -t priv -f openssl -x -T /usr/bin/codesign\n"),
                runner: runner)
            try await security(
                "security import (certificates)",
                SensitiveText("import \(VMIdentityStore.quoted(certificates)) -k \(VMIdentityStore.quoted(keychain.path)) -t cert -f pemseq\n"),
                runner: runner, tolerating: "already exists")
            try await keychain.allowCodesign(runner: runner)
        }
        return keychain
    }

    private static func openssl(
        _ arguments: [String], input: SensitiveText?, _ what: String, runner: any ProcessRunner
    ) async throws {
        let outcome = try await runner.run(
            ProcessCommand(executable: "/usr/bin/openssl", arguments: arguments, environment: CIKeychain.environment, standardInput: input),
            onLine: { _ in })
        guard outcome.exitCode == 0 else { throw CIKeychainError.failed("openssl (\(what))", exitCode: outcome.exitCode) }
    }

    private static func security(
        _ what: String, _ input: SensitiveText, runner: any ProcessRunner, tolerating: String? = nil
    ) async throws {
        let outcome = try await runner.run(
            ProcessCommand(executable: "/usr/bin/security", arguments: ["-i"], environment: CIKeychain.environment, standardInput: input),
            onLine: { _ in })
        if outcome.exitCode != 0, let tolerating, outcome.output.contains(tolerating) { return }
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
