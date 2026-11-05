import Foundation
import HangarCore

/// Probes this machine for the health data the scheduler uses for eligibility. Never throws: a failed probe
/// yields a conservative default (0, empty, false).
public struct Doctor: Sendable {
    private let runner: any ProcessRunner
    private let locator: XcodeLocator
    private let knownTools: [String]
    private let dataDirectory: String
    private let clock: any Clock<Duration>
    private let signTimeout: Duration

    public init(
        runner: any ProcessRunner, locator: XcodeLocator,
        knownTools: [String] = ["git", "brew", "xcodegen", "rclone", "sentry-cli"],
        dataDirectory: String = NSHomeDirectory(), clock: any Clock<Duration> = ContinuousClock(),
        signTimeout: Duration = .seconds(10)
    ) {
        self.runner = runner
        self.locator = locator
        self.knownTools = knownTools
        self.dataDirectory = dataDirectory
        self.clock = clock
        self.signTimeout = signTimeout
    }

    public func report(runningJobIDs: [UUID]) async -> MachineReport {
        async let canSign = canSignWithoutPrompt()
        let bytes = Int(await sysctl("hw.memsize")) ?? 0
        return MachineReport(
            macOSVersion: await output("/usr/bin/sw_vers", ["-productVersion"]) ?? "",
            xcodes: (try? await locator.installed()) ?? [],
            chip: await sysctl("machdep.cpu.brand_string"),
            performanceCores: Int(await sysctl("hw.perflevel0.physicalcpu")) ?? 0,
            memoryGB: Int((Double(bytes) / 1_073_741_824).rounded()),
            freeDiskGB: freeDiskGB(),
            onACPower: await onACPower(),
            tools: await tools(),
            canSignWithoutPrompt: await canSign,
            runningJobIDs: runningJobIDs,
            simulatorRuntimes: await simulatorRuntimes())
    }

    // MARK: Probes

    private static let environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        "HOME": NSHomeDirectory(),
    ].merging(CIEnvironment.identityEnvironment(from: ProcessInfo.processInfo.environment).filter { $0.key != "HOME" }) {
        base, _ in base
    }

    /// Trimmed output of a successful run; nil on a non-zero exit or a launch failure.
    private func output(_ executable: String, _ arguments: [String]) async -> String? {
        let command = ProcessCommand(executable: executable, arguments: arguments, environment: Self.environment)
        guard let outcome = try? await runner.run(command, onLine: { _ in }), outcome.exitCode == 0 else { return nil }
        return outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sysctl(_ key: String) async -> String {
        await output("/usr/sbin/sysctl", ["-n", key]) ?? ""
    }

    private func freeDiskGB() -> Double {
        let url = URL(fileURLWithPath: dataDirectory)
        let bytes = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return Double(bytes ?? 0) / 1_000_000_000
    }

    /// Battery power is the only "not AC" signal; a desktop prints no battery source and counts as AC.
    private func onACPower() async -> Bool {
        guard let text = await output("/usr/bin/pmset", ["-g", "batt"]) else { return false }
        if text.contains("'AC Power'") { return true }
        return !text.contains("'Battery Power'")
    }

    /// Runtimes with an available simulator, through the Xcode `xcode-select` points at.
    private func simulatorRuntimes() async -> [String] {
        guard let json = await output("/usr/bin/xcrun", SimulatorCatalog.listArguments) else { return [] }
        return SimulatorCatalog.runtimeNames(SimulatorCatalog.devices(fromJSON: Data(json.utf8)))
    }

    private func tools() async -> [String: String] {
        var found: [String: String] = [:]
        for name in knownTools where name.wholeMatch(of: /[A-Za-z0-9._+-]+/) != nil {
            if let path = await output("/bin/sh", ["-c", "command -v \(name)"]), !path.isEmpty { found[name] = path }
        }
        return found
    }

    // MARK: Signing

    /// Signs a throwaway copy of `/bin/ls` with the first Apple Development identity. A keychain prompt makes
    /// codesign hang, so the attempt is raced against `signTimeout`.
    private func canSignWithoutPrompt() async -> Bool {
        guard let hash = await developmentIdentityHash() else { return false }
        let target = NSTemporaryDirectory() + "hangar-doctor-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: target) }
        do { try FileManager.default.copyItem(atPath: "/bin/ls", toPath: target) } catch { return false }

        let command = ProcessCommand(
            executable: "/usr/bin/codesign", arguments: ["--force", "--sign", hash, target],
            environment: Self.environment)
        let runner = runner, clock = clock, timeout = signTimeout
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await runner.run(command, onLine: { _ in }))?.exitCode == 0 }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// SHA-1 of the first "Apple Development" identity; sign by hash so several identities are unambiguous.
    private func developmentIdentityHash() async -> String? {
        guard let text = await output("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]) else {
            return nil
        }
        for line in text.split(separator: "\n") where line.contains("Apple Development") {
            if let match = line.firstMatch(of: /\)\s+([0-9A-Fa-f]{40})\s/) { return String(match.1) }
        }
        return nil
    }
}
