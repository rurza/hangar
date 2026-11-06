import Foundation
import HangarCore

public enum JobKeychainError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case wrongPassword
    /// It could not be created; the reason is the setup's own error.
    case unavailable(String)
    case failed(String, exitCode: Int32)

    public var description: String {
        switch self {
        case .missing(let path): "there is no job keychain at \(path)"
        case .wrongPassword: "the job keychain does not unlock with its password"
        case .unavailable(let reason): "it could not be set up: \(reason)"
        case .failed(let what, let exitCode): "\(what) exited with status \(exitCode)"
        }
    }
}

/// The keychain a VM job signs with (`GuestKeychain`): created in the guest for one job with a random password that
/// stays in the guest worker's memory. A VM has no login keychain unlocked for the job, so before the job's first
/// step `JobRunner` unlocks this one and keeps it the default and first on the search list, where xcodebuild puts a
/// new signing identity and where codesign looks for one; after anything that can add a key it lets codesign use
/// every key without the "Always Allow" prompt nobody is there to click. A local build signs with the owner's login
/// keychain instead and has none.
///
/// The password reaches `security` only on standard input (`security -i`, one command per run, so its exit status is
/// that command's): never on a command line, in a log or on the server.
public struct JobKeychain: Sendable, Equatable {
    /// Who may use a signing key without asking: Apple's command-line tools, Apple-signed apps (Xcode) and codesign.
    public static let partitions = "apple-tool:,apple:,codesign:"

    public var path: String
    private var password: SensitiveText?
    /// Why the keychain could not be created; `prepare` then fails with it, so the job does too.
    private var setupFailure: String?

    /// A keychain whose password lives only in this process.
    public init(path: String, password: SensitiveText) {
        self.path = path
        self.password = password
    }

    /// A keychain that could not be set up: the job fails at its first step, saying why.
    public init(path: String, failure: String) {
        self.path = path
        self.setupFailure = failure
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
        guard FileManager.default.fileExists(atPath: path) else { throw JobKeychainError.missing(path) }
        let unlock = try await security(["-i"], input: Self.unlockInput(password: password, path: path), runner: runner)
        guard unlock.exitCode == 0 else { throw JobKeychainError.wrongPassword }

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
            throw JobKeychainError.failed("security set-key-partition-list", exitCode: outcome.exitCode)
        }
    }

    // MARK: Helpers

    func readPassword() throws -> SensitiveText {
        if let setupFailure { throw JobKeychainError.unavailable(setupFailure) }
        guard let password else { throw JobKeychainError.unavailable("it has no password") }
        return password
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
        guard outcome.exitCode == 0 else { throw JobKeychainError.failed(what, exitCode: outcome.exitCode) }
    }
}
