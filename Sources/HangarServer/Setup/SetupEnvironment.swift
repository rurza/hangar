import Foundation
import HangarCore
import Synchronization

/// What the first-run setup reads from the Mac the server runs on: the home directory and the working directory
/// (for API key files), the server's environment, the tools it runs (`gh`, `scutil`) and the worker installer.
/// Tests pass a temporary home, a `RecordingProcessRunner` and a fake installer.
public struct SetupEnvironment: Sendable {
    public var homeDirectory: String
    public var currentDirectory: String
    /// The server's own environment; children get it with Homebrew's directories added to `PATH`.
    public var environment: [String: String]
    public var runner: any ProcessRunner
    public var installer: any LocalWorkerInstaller

    public init(
        homeDirectory: String, currentDirectory: String, environment: [String: String], runner: any ProcessRunner,
        installer: any LocalWorkerInstaller
    ) {
        self.homeDirectory = homeDirectory
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.runner = runner
        self.installer = installer
    }

    /// The running server's: `HOME` (else the account's home), its working directory and environment.
    public static func live() -> SetupEnvironment {
        let environment = ProcessInfo.processInfo.environment
        let runner = LiveProcessRunner()
        return SetupEnvironment(
            homeDirectory: environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory(),
            currentDirectory: FileManager.default.currentDirectoryPath, environment: environment, runner: runner,
            installer: ScriptWorkerInstaller(runner: runner))
    }

    /// The server's environment for a child process, with the system and Homebrew directories on `PATH` (a
    /// launchd agent starts with a bare one).
    var childEnvironment: [String: String] {
        var environment = environment
        var path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !path.contains(directory) {
            path.append(directory)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    /// Trimmed output of `executable` when it exits 0 within `timeout`; nil otherwise. A non-absolute executable is
    /// found on the child's `PATH`.
    func output(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(15)) async -> String? {
        let command: ProcessCommand =
            executable.hasPrefix("/")
            ? ProcessCommand(executable: executable, arguments: arguments, environment: childEnvironment)
            : ProcessCommand(executable: "/usr/bin/env", arguments: [executable] + arguments, environment: childEnvironment)
        let runner = runner
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                guard let outcome = try? await runner.run(command, onLine: { _ in }), outcome.exitCode == 0 else { return nil }
                return outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// This Mac's local host name (`scutil --get LocalHostName`), read once it is known.
final class LocalHostName: Sendable {
    private let cached = Mutex<String?>(nil)

    func value(_ environment: SetupEnvironment) async -> String? {
        if let name = cached.withLock({ $0 }) { return name }
        guard let name = await environment.output("/usr/sbin/scutil", ["--get", "LocalHostName"]), !name.isEmpty,
            !name.contains(where: \.isNewline)
        else { return nil }
        cached.withLock { $0 = name }
        return name
    }
}
