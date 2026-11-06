import Foundation
import HangarCore

public enum Hook: String, CaseIterable, Sendable {
    case postClone = "ci_post_clone.sh"
    case preXcodebuild = "ci_pre_xcodebuild.sh"
    case postXcodebuild = "ci_post_xcodebuild.sh"
}

public enum HookOutcome: Equatable, Sendable {
    case absent, ran
}

public enum HookError: Error, Equatable, CustomStringConvertible {
    case failed(hook: Hook, exitCode: Int32)

    public var description: String {
        switch self {
        case .failed(let hook, let exitCode): "\(hook.rawValue) exited with status \(exitCode)"
        }
    }
}

/// Runs a repository's Xcode Cloud `ci_scripts` hooks the way Xcode Cloud does: from inside `ci_scripts`, with the
/// given environment and nothing else. What a hook leaves running goes to `leftovers`, to be stopped with the job.
public struct HookRunner: Sendable {
    private let runner: any ProcessRunner
    private let leftovers: ProcessGroups?

    public init(runner: any ProcessRunner, leftovers: ProcessGroups? = nil) {
        self.runner = runner
        self.leftovers = leftovers
    }

    /// `scriptsDirectory` is `<repository>/<projectDirectory>/ci_scripts`. A missing hook (or a directory with its
    /// name) is skipped. A script without the executable bit still runs, through `/bin/sh`, with a warning.
    public func run(
        _ hook: Hook, scriptsDirectory: String, environment: [String: String], log: @escaping @Sendable (String) -> Void
    ) async throws -> HookOutcome {
        let script = scriptsDirectory + "/" + hook.rawValue
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: script, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .absent
        }

        let command: ProcessCommand
        if FileManager.default.isExecutableFile(atPath: script) {
            command = ProcessCommand(
                executable: script, arguments: [], environment: environment, currentDirectory: scriptsDirectory,
                leftovers: leftovers)
        } else {
            log("warning: ci_scripts/\(hook.rawValue) is not executable; running it with /bin/sh (Xcode Cloud requires chmod +x)")
            command = ProcessCommand(
                executable: "/bin/sh", arguments: [script], environment: environment, currentDirectory: scriptsDirectory,
                leftovers: leftovers)
        }
        let outcome = try await runner.run(command, onLine: log)
        guard outcome.exitCode == 0 else { throw HookError.failed(hook: hook, exitCode: outcome.exitCode) }
        return .ran
    }
}
