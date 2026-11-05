import Foundation
import HangarCore
import Synchronization

/// Runs the worker install script on the server's own Mac. The seam tests replace.
public protocol LocalWorkerInstaller: Sendable {
    /// Runs `script` with exactly `environment`, delivering its output line by line; returns its exit status.
    func run(script: String, environment: [String: String], onLine: @escaping @Sendable (String) -> Void) async throws -> Int32
}

/// The live installer: `/bin/sh -c <script>`, the same script `GET /install` serves.
public struct ScriptWorkerInstaller: LocalWorkerInstaller {
    let runner: any ProcessRunner

    public init(runner: any ProcessRunner) { self.runner = runner }

    public func run(script: String, environment: [String: String], onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try await runner.run(
            ProcessCommand(executable: "/bin/sh", arguments: ["-c", script, "hangar-install"], environment: environment),
            onLine: onLine
        ).exitCode
    }
}

/// "Use This Mac for Builds": at most one install at a time, its output kept for the setup page to poll.
final class LocalWorkerSetup: Sendable {
    /// The output lines kept.
    static let maximumLines = 200

    private let state = Mutex<LocalWorkerInstall?>(nil)
    let timeout: Duration

    init(timeout: Duration = .seconds(600)) { self.timeout = timeout }

    var current: LocalWorkerInstall? { state.withLock { $0 } }

    /// Reserves the one install slot: nil when an install is running already.
    func reserve() -> LocalWorkerInstall? {
        state.withLock { state -> LocalWorkerInstall? in
            if let state, state.state == .running { return nil }
            state = LocalWorkerInstall(state: .running)
            return state
        }
    }

    /// Runs `install` in the reserved slot. `secret` is masked in every output line; `finish` names the enrolled
    /// machine once the script has succeeded (none is a failure). An install still running after `timeout` is
    /// cancelled and fails.
    func run(
        secret: String, install: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> Int32,
        finish: @escaping @Sendable () throws -> Machine?
    ) {
        let timeout = timeout
        Task {
            let onLine: @Sendable (String) -> Void = { [self] line in
                let masked = line.replacingOccurrences(of: secret, with: "••••")
                    .replacingOccurrences(of: secret.replacingOccurrences(of: "-", with: ""), with: "••••")
                self.state.withLock { install in
                    install?.lines.append(masked)
                    if let count = install?.lines.count, count > Self.maximumLines {
                        install?.lines.removeFirst(count - Self.maximumLines)
                    }
                }
            }
            var result: LocalWorkerInstall.State = .failed
            var machine: Machine?
            var message: String?
            do {
                let status = try await withThrowingTaskGroup(of: Int32?.self) { group in
                    group.addTask { try await install(onLine) }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return nil
                    }
                    let first = try await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
                if let status, status == 0 {
                    machine = try finish()
                    if machine != nil {
                        result = .succeeded
                    } else {
                        message = "The install script finished but did not enroll this Mac. See its output below."
                    }
                } else if let status {
                    let last = state.withLock { $0?.lines.last { $0.hasPrefix("error: ") } }
                    message = "The install script exited with status \(status)."
                        + (last.map { " " + $0.dropFirst("error: ".count) } ?? "")
                } else {
                    message = "The install script did not finish within \(timeout.components.seconds / 60) minutes and was stopped."
                }
            } catch {
                message = "The install script could not run: \(error.localizedDescription)"
            }
            state.withLock { install in
                install?.state = result
                install?.machine = machine
                install?.message = message
            }
        }
    }
}
