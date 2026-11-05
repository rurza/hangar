import Foundation
import HangarCore

public enum CIKeychainError: Error, Equatable, CustomStringConvertible {
    case passwordUnreadable(String)
    case missing(String)
    case wrongPassword
    case failed(String, exitCode: Int32)

    public var description: String {
        switch self {
        case .passwordUnreadable(let path): "cannot read the CI keychain's password file \(path); run hangar-worker isolate again"
        case .missing(let path): "there is no CI keychain at \(path); run hangar-worker isolate again"
        case .wrongPassword: "the CI keychain does not unlock with its stored password; run hangar-worker isolate again"
        case .failed(let what, let exitCode): "\(what) exited with status \(exitCode)"
        }
    }
}

/// The keychain a headless worker signs with (worker isolation design, *revised: LaunchDaemon*):
/// `hangar-ci.keychain-db` in the `hangar` home, created by `hangar-worker isolate` with a generated password that
/// stays in a 0600 file next to the worker's configuration. A LaunchDaemon has no login, so no login keychain is
/// unlocked for it. Before every job (and every heartbeat's doctor) the worker unlocks this keychain and keeps it the
/// default and on the search list, where xcodebuild puts a new signing identity and where codesign looks for one;
/// after anything that can add a key it lets codesign use every key without the "Always Allow" prompt nobody is there
/// to click.
///
/// The password reaches `security` only on standard input (`security -i`, one command per run, so its exit status is
/// that command's): never on a command line, in a log or on the server.
public struct CIKeychain: Sendable, Equatable {
    public static let fileName = "hangar-ci.keychain-db"
    public static let passwordFileName = "keychain-password"
    /// Who may use a signing key without asking: Apple's command-line tools, Apple-signed apps (Xcode) and codesign.
    public static let partitions = "apple-tool:,apple:,codesign:"

    public var path: String
    public var passwordFile: String

    public init(path: String, passwordFile: String) {
        self.path = path
        self.passwordFile = passwordFile
    }

    /// Where `isolate` puts them for the user whose home is `home`.
    public init(home: String) {
        self.init(
            path: home + "/Library/Keychains/" + Self.fileName,
            passwordFile: home + "/Library/Application Support/Hangar/worker/" + Self.passwordFileName)
    }

    /// This user's CI keychain when `isolate` set one up, nil otherwise. Its password file is what makes a worker
    /// headless: a worker in a login session (any user's agent) has none and signs as before.
    public static func installed(home: String = NSHomeDirectory()) -> CIKeychain? {
        let keychain = CIKeychain(home: home)
        return FileManager.default.fileExists(atPath: keychain.passwordFile) ? keychain : nil
    }

    // MARK: security -i input

    /// The standard input of `security -i` for one command. The path is quoted; the password is from
    /// `RandomPasswordGenerator`, so it needs no quoting.
    static func input(_ command: String, password: SensitiveText, path: String) -> SensitiveText {
        SensitiveText("\(command) \(password.value) \"\(path)\"\n")
    }

    public static func createInput(password: SensitiveText, path: String) -> SensitiveText {
        input("create-keychain -p", password: password, path: path)
    }

    public static func unlockInput(password: SensitiveText, path: String) -> SensitiveText {
        input("unlock-keychain -p", password: password, path: path)
    }

    public static func partitionListInput(password: SensitiveText, path: String) -> SensitiveText {
        input("set-key-partition-list -S \(partitions) -s -k", password: password, path: path)
    }

    // MARK: Before a job

    /// Unlocks the keychain and makes it the default and the first on the user's search list (keeping the others).
    /// Cheap enough for every heartbeat; changes the settings only when they differ.
    public func prepare(runner: any ProcessRunner) async throws {
        let password = try readPassword()
        guard FileManager.default.fileExists(atPath: path) else { throw CIKeychainError.missing(path) }
        let unlock = try await security(["-i"], input: Self.unlockInput(password: password, path: path), runner: runner)
        guard unlock.exitCode == 0 else { throw CIKeychainError.wrongPassword }

        let current = try await security(["default-keychain", "-d", "user"], runner: runner)
        if !(current.exitCode == 0 && Self.paths(in: current.output).first.map(isThisKeychain) == true) {
            try await require(["default-keychain", "-d", "user", "-s", path], "security default-keychain", runner: runner)
        }
        let list = try await security(["list-keychains", "-d", "user"], runner: runner)
        let listed = list.exitCode == 0 ? Self.paths(in: list.output) : []
        if listed.first.map(isThisKeychain) != true {
            let others = listed.filter { !isThisKeychain($0) }
            try await require(["list-keychains", "-d", "user", "-s", path] + others, "security list-keychains", runner: runner)
        }
    }

    /// Lets codesign, productbuild and Xcode use every signing key in the keychain without a prompt
    /// (`set-key-partition-list`). Run after a step that can create a key; a keychain with no key yet is fine.
    public func allowCodesign(runner: any ProcessRunner) async throws {
        let password = try readPassword()
        let outcome = try await security(["-i"], input: Self.partitionListInput(password: password, path: path), runner: runner)
        guard outcome.exitCode == 0 || outcome.output.contains("could not be found") else {
            throw CIKeychainError.failed("security set-key-partition-list", exitCode: outcome.exitCode)
        }
    }

    /// Nil when `prepare` works; otherwise what is wrong, as the doctor reports it.
    public func problem(runner: any ProcessRunner) async -> String? {
        do {
            try await prepare(runner: runner)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    // MARK: Helpers

    func readPassword() throws -> SensitiveText {
        guard let text = try? String(contentsOfFile: passwordFile, encoding: .utf8) else {
            throw CIKeychainError.passwordUnreadable(passwordFile)
        }
        let password = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { throw CIKeychainError.passwordUnreadable(passwordFile) }
        return SensitiveText(password)
    }

    /// The quoted paths `security default-keychain` and `list-keychains` print, one per line.
    static func paths(in output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return nil }
            return String(trimmed.dropFirst().dropLast())
        }
    }

    /// `security` prints resolved paths (`/private/var/...` for `/var/...`).
    private func isThisKeychain(_ other: String) -> Bool {
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        return resolved(other) == resolved(path)
    }

    static let environment = CIEnvironment.identityEnvironment(from: ProcessInfo.processInfo.environment)
        .merging(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]) { _, new in new }

    private func security(
        _ arguments: [String], input: SensitiveText? = nil, runner: any ProcessRunner
    ) async throws -> ProcessOutcome {
        try await runner.run(
            ProcessCommand(
                executable: "/usr/bin/security", arguments: arguments, environment: Self.environment, standardInput: input),
            onLine: { _ in })
    }

    private func require(_ arguments: [String], _ what: String, runner: any ProcessRunner) async throws {
        let outcome = try await security(arguments, runner: runner)
        guard outcome.exitCode == 0 else { throw CIKeychainError.failed(what, exitCode: outcome.exitCode) }
    }
}
