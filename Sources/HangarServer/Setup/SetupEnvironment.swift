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
    /// Whether a request's socket peer (an IP address, nil when unknown) is this Mac. Nil: `LocalPeer.isLocal`
    /// with the bound address and this Mac's interface addresses. The router test client has no peer, so tests
    /// decide here.
    public var isLocalPeer: (@Sendable (String?) -> Bool)?

    public init(
        homeDirectory: String, currentDirectory: String, environment: [String: String], runner: any ProcessRunner,
        installer: any LocalWorkerInstaller, isLocalPeer: (@Sendable (String?) -> Bool)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.runner = runner
        self.installer = installer
        self.isLocalPeer = isLocalPeer
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

    /// The variables of the server's environment the install script may see: the basics, and the documented
    /// overrides of where the worker goes (`HANGAR_BIN_DIR`, `HANGAR_WORKER_CONFIG`) and `HANGAR_NO_LAUNCHD`
    /// (testing). Nothing else of the server's environment reaches it.
    static let scriptVariables = [
        "HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL", "HANGAR_BIN_DIR", "HANGAR_WORKER_CONFIG",
        "HANGAR_NO_LAUNCHD",
    ]

    var scriptEnvironment: [String: String] {
        childEnvironment.filter { Self.scriptVariables.contains($0.key) && !$0.value.isEmpty }
    }

    /// The worker configuration file the install script uses: `HANGAR_WORKER_CONFIG`, else hangar-worker's default.
    var workerConfigPath: String {
        if let path = environment["HANGAR_WORKER_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: currentDirectory)).path
        }
        return URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support/Hangar/worker/config.json").path
    }

    /// A worker already set up here: its configuration file exists, or this user's launch agent is loaded (not asked
    /// under `HANGAR_NO_LAUNCHD=1`, where the script leaves launchd alone). Nil when none. A `launchctl print` that does not answer within `probeTimeout` counts as
    /// no job, so the page never hangs.
    func installedWorker(probeTimeout: Duration = .seconds(5)) async -> InstalledWorker? {
        var serverURL: String?
        let hasConfig = FileManager.default.fileExists(atPath: workerConfigPath)
        if hasConfig, let data = FileManager.default.contents(atPath: workerConfigPath),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            serverURL = object["serverURL"] as? String
        }
        var loaded = false
        if environment["HANGAR_NO_LAUNCHD"] != "1" {
            loaded = await output("/bin/launchctl", ["print", "gui/\(getuid())/app.hangar.worker"], timeout: probeTimeout) != nil
        }
        guard hasConfig || loaded else { return nil }
        return InstalledWorker(serverURL: serverURL, agentLoaded: loaded)
    }

    /// The last non-empty output line of `executable` when it exits 0 within `timeout`; nil otherwise. stderr is
    /// merged into the output, so a warning before the answer is skipped.
    func lastLine(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(15)) async -> String? {
        await output(executable, arguments, timeout: timeout)?
            .split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) }
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
