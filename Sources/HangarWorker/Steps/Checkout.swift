import Foundation
import HangarCore

public enum CheckoutError: Error, Equatable, CustomStringConvertible {
    /// `command` is the display form of the git invocation; it never contains the token.
    case gitFailed(command: String, exitCode: Int32)

    public var description: String {
        switch self {
        case .gitFailed(let command, let exitCode): "\(command) exited with status \(exitCode)"
        }
    }
}

/// Brings the cached per-app workspace to exactly `commit`, with no leftovers from earlier builds.
public struct Checkout: Sendable {
    private let runner: any ProcessRunner
    private let layout: WorkspaceLayout
    private let extraEnvironment: [String: String]

    /// `extraEnvironment` is added to every git child (the token settings win on a clash); tests use it to allow
    /// `file://` submodules.
    public init(runner: any ProcessRunner, layout: WorkspaceLayout, extraEnvironment: [String: String] = [:]) {
        self.runner = runner
        self.layout = layout
        self.extraEnvironment = extraEnvironment
    }

    public func run(repoURL: String, commit: String, token: String?, log: @escaping @Sendable (String) -> Void) async throws {
        let fileManager = FileManager.default
        let repository = layout.repository
        try fileManager.createDirectory(
            atPath: (repository as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // A directory without .git is what an interrupted clone leaves behind.
        if fileManager.fileExists(atPath: repository), !fileManager.fileExists(atPath: repository + "/.git") {
            try fileManager.removeItem(atPath: repository)
        }

        if fileManager.fileExists(atPath: repository + "/.git") {
            let remote = try await git(["-C", repository, "remote", "get-url", "origin"], token: token, log: log)
            if remote.trimmingCharacters(in: .whitespacesAndNewlines) != repoURL {
                try await git(["-C", repository, "remote", "set-url", "origin", repoURL], token: token, log: log)
            }
            try await git(["-C", repository, "fetch", "--prune", "--tags", "--force", "origin"], token: token, log: log)
        } else {
            try await git(["clone", repoURL, repository], token: token, log: log)
        }

        // Tracked files edited by an earlier build's scripts must neither block the checkout nor carry over.
        try await git(["-C", repository, "reset", "--hard"], token: token, log: log)
        do {
            try await git(["-C", repository, "checkout", "--detach", commit], token: token, log: log)
        } catch CheckoutError.gitFailed {
            // The commit may sit on a ref the plain fetch does not cover.
            try await git(["-C", repository, "fetch", "origin", commit], token: token, log: log)
            try await git(["-C", repository, "checkout", "--detach", commit], token: token, log: log)
        }
        // reset --hard leaves submodule worktrees alone, and a moved submodule URL needs syncing first.
        try await git(["-C", repository, "submodule", "sync", "--recursive"], token: token, log: log)
        try await git(
            ["-C", repository, "submodule", "foreach", "--recursive", "git reset --hard"], token: token, log: log)
        try await git(
            ["-C", repository, "submodule", "update", "--init", "--recursive", "--force"], token: token, log: log)
        // Doubled -f: a single one skips nested git repositories (SwiftPM checkouts, repos cloned by scripts).
        try await git(["-C", repository, "clean", "-ffdx"], token: token, log: log)
        try await git(
            ["-C", repository, "submodule", "foreach", "--recursive", "git clean -ffdx"], token: token, log: log)
    }

    @discardableResult
    private func git(_ arguments: [String], token: String?, log: @escaping @Sendable (String) -> Void) async throws -> String {
        let display = (["git"] + arguments).joined(separator: " ")
        log(display)
        let environment = Self.environment(token: token, extra: extraEnvironment)
        let outcome = try await runner.run(
            ProcessCommand(executable: "/usr/bin/git", arguments: arguments, environment: environment), onLine: log)
        guard outcome.exitCode == 0 else { throw CheckoutError.gitFailed(command: display, exitCode: outcome.exitCode) }
        return outcome.output
    }

    /// The complete environment of a git child: a fixed `PATH` and `HOME`, the user name, temp directory and locale, no prompts, no system gitconfig, and the
    /// token's `credentialEnvironment` when there is a token.
    static func environment(token: String?, extra: [String: String] = [:]) -> [String: String] {
        let base = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
        ].merging(CIEnvironment.identityEnvironment(from: ProcessInfo.processInfo.environment).filter { $0.key != "HOME" }) {
            base, _ in base
        }
        return extra.merging(base) { _, new in new }.merging(token.map(credentialEnvironment) ?? [:]) { _, new in new }
    }

    /// What lets any git child (ours, or the one xcodebuild runs to resolve packages) authenticate to github.com with
    /// the token. The helper reads the token from `HANGAR_GITHUB_TOKEN`, so it never lands in a URL or `.git/config`.
    /// The two empty values reset any helper from the user's gitconfig (generic and github.com-scoped), so nothing
    /// like osxkeychain can store the token, and ours answers for github.com only.
    static func credentialEnvironment(token: String) -> [String: String] {
        [
            "GIT_CONFIG_COUNT": "3",
            "GIT_CONFIG_KEY_0": "credential.helper",
            "GIT_CONFIG_VALUE_0": "",
            "GIT_CONFIG_KEY_1": "credential.https://github.com.helper",
            "GIT_CONFIG_VALUE_1": "",
            "GIT_CONFIG_KEY_2": "credential.https://github.com.helper",
            "GIT_CONFIG_VALUE_2": "!f() { echo username=x-access-token; echo password=$HANGAR_GITHUB_TOKEN; }; f",
            "HANGAR_GITHUB_TOKEN": token,
        ]
    }
}
