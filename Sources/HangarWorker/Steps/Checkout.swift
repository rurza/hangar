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

    public init(runner: any ProcessRunner, layout: WorkspaceLayout) {
        self.runner = runner
        self.layout = layout
    }

    public func run(repoURL: String, commit: String, token: String?, log: @Sendable (String) -> Void) async throws {
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
        try await git(["-C", repository, "submodule", "update", "--init", "--recursive"], token: token, log: log)
        try await git(["-C", repository, "clean", "-fdx"], token: token, log: log)
        try await git(
            ["-C", repository, "submodule", "foreach", "--recursive", "git clean -fdx"], token: token, log: log)
    }

    @discardableResult
    private func git(_ arguments: [String], token: String?, log: @Sendable (String) -> Void) async throws -> String {
        let display = (["git"] + arguments).joined(separator: " ")
        log(display)
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
        ]
        if let token {
            // The helper reads the token from the child's environment, so it never lands in a URL or .git/config.
            environment["GIT_CONFIG_COUNT"] = "1"
            environment["GIT_CONFIG_KEY_0"] = "credential.helper"
            environment["GIT_CONFIG_VALUE_0"] =
                "!f() { echo username=x-access-token; echo password=$HANGAR_GITHUB_TOKEN; }; f"
            environment["HANGAR_GITHUB_TOKEN"] = token
        }
        let outcome = try await runner.run(
            ProcessCommand(executable: "/usr/bin/git", arguments: arguments, environment: environment), onLine: log)
        guard outcome.exitCode == 0 else { throw CheckoutError.gitFailed(command: display, exitCode: outcome.exitCode) }
        return outcome.output
    }
}
