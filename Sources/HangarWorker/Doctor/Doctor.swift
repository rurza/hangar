import Foundation
import HangarCore
import Synchronization

/// Probes this machine for the health data the scheduler uses for eligibility. Never throws: a failed probe
/// yields a conservative default (0, empty, false).
public struct Doctor: Sendable {
    private let runner: any ProcessRunner
    private let locator: XcodeLocator
    private let knownTools: [String]
    private let dataDirectory: String
    private let clock: any Clock<Duration>
    private let signTimeout: Duration
    private let simulatorTimeout: Duration
    private let simulatorRefresh: TimeInterval
    private let now: @Sendable () -> Date
    private let userName: String
    /// Set when VM builds are on: the report's `vm` section.
    private let vm: VMDoctor?
    /// The last simulator runtimes listed and when the list was last attempted, shared by the copies of this Doctor.
    private let simulators = SimulatorListCache()

    /// `simctl` gets `simulatorTimeout` and is asked again only every `simulatorRefresh` seconds (by `now`), so a
    /// slow or wedged CoreSimulatorService cannot hold up the heartbeat; a failed listing keeps the last good one.
    public init(
        runner: any ProcessRunner, locator: XcodeLocator,
        knownTools: [String] = ["git", "brew", "xcodegen", "rclone", "sentry-cli"],
        dataDirectory: String = NSHomeDirectory(), clock: any Clock<Duration> = ContinuousClock(),
        signTimeout: Duration = .seconds(10), simulatorTimeout: Duration = .seconds(10),
        simulatorRefresh: TimeInterval = 600, now: @escaping @Sendable () -> Date = Date.init,
        userName: String = NSUserName(), vm: VMDoctor? = nil
    ) {
        self.vm = vm
        self.userName = userName
        self.simulatorTimeout = simulatorTimeout
        self.simulatorRefresh = simulatorRefresh
        self.now = now
        self.runner = runner
        self.locator = locator
        self.knownTools = knownTools
        self.dataDirectory = dataDirectory
        self.clock = clock
        self.signTimeout = signTimeout
    }

    /// With VM builds on, the host's keychain signs nothing (each VM gets the server's identity): it is not probed,
    /// and the report lists no identities. A local build signs with the owner's login keychain, which is probed.
    public func report(runningJobIDs: [UUID]) async -> MachineReport {
        let identities = vm == nil ? await signingIdentities() : []
        async let canSign = vm == nil ? canSignWithoutPrompt(identities: identities) : false
        async let xcodeAccount = xcodeAccountSignedIn()
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
            signingIdentities: Self.uniqueNames(identities),
            xcodeAccountSignedIn: await xcodeAccount,
            simulatorRuntimes: await simulatorRuntimes(),
            capabilities: WorkerCapability.all,
            runningUser: userName,
            vm: vm?.report(runningJobs: runningJobIDs.count))
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

    /// "Important usage" counts purgeable space but can read 0 (outside a login session), so the plain available
    /// capacity stands in for it then.
    private func freeDiskGB() -> Double {
        let url = URL(fileURLWithPath: dataDirectory)
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        let important = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let bytes = important > 0 ? important : Int64(values?.volumeAvailableCapacity ?? 0)
        return Double(bytes) / 1_000_000_000
    }

    /// Battery power is the only "not AC" signal; a desktop prints no battery source and counts as AC.
    private func onACPower() async -> Bool {
        guard let text = await output("/usr/bin/pmset", ["-g", "batt"]) else { return false }
        if text.contains("'AC Power'") { return true }
        return !text.contains("'Battery Power'")
    }

    /// Runtimes with an available simulator, through the Xcode `xcode-select` points at; cached, see `init`.
    private func simulatorRuntimes() async -> [String] {
        let date = now()
        let cached = simulators.withLock { $0 }
        if let attempted = cached.attemptedAt, date.timeIntervalSince(attempted) < simulatorRefresh { return cached.runtimes }
        let command = ProcessCommand(
            executable: "/usr/bin/xcrun", arguments: SimulatorCatalog.listArguments, environment: Self.environment,
            discardsStandardError: true)
        let runner = runner, clock = clock, timeout = simulatorTimeout
        let listed = await withTaskGroup(of: [String]?.self) { group in
            group.addTask {
                guard let outcome = try? await runner.run(command, onLine: { _ in }), outcome.exitCode == 0,
                    let devices = SimulatorCatalog.list(fromJSON: Data(outcome.output.utf8))
                else { return nil }
                return SimulatorCatalog.runtimeNames(devices)
            }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return simulators.withLock { state in
            state.attemptedAt = date
            if let listed { state.runtimes = listed }
            return state.runtimes
        }
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
    private func canSignWithoutPrompt(identities: [SigningIdentity]) async -> Bool {
        guard let hash = identities.first(where: { $0.name.hasPrefix("Apple Development") })?.hash else { return false }
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

    struct SigningIdentity: Equatable {
        var hash: String
        var name: String
    }

    /// The valid code signing identities, in `security find-identity` order; empty when it fails.
    private func signingIdentities() async -> [SigningIdentity] {
        let command = ProcessCommand(
            executable: "/usr/bin/security", arguments: ["find-identity", "-v", "-p", "codesigning"],
            environment: Self.environment)
        guard let outcome = await bounded(command), outcome.exitCode == 0 else { return [] }
        let text = outcome.output
        return text.split(separator: "\n").compactMap { line in
            line.firstMatch(of: /\)\s+([0-9A-Fa-f]{40})\s+"(.+)"/).map { SigningIdentity(hash: String($0.1), name: String($0.2)) }
        }
    }

    /// The identity names without repeats (two certificates may share a name), first occurrence first.
    static func uniqueNames(_ identities: [SigningIdentity]) -> [String] {
        var seen = Set<String>()
        return identities.map(\.name).filter { seen.insert($0).inserted }
    }

    /// Whether Xcode lists an Apple account (`DVTDeveloperAccountManagerAppleIDLists` names an identifier). nil
    /// when `defaults` cannot run at all.
    private func xcodeAccountSignedIn() async -> Bool? {
        let command = ProcessCommand(
            executable: "/usr/bin/defaults", arguments: ["read", "com.apple.dt.Xcode", "DVTDeveloperAccountManagerAppleIDLists"],
            environment: Self.environment)
        guard let outcome = await bounded(command) else { return nil }
        return outcome.exitCode == 0 && outcome.output.contains("identifier")
    }

    /// `command`'s outcome, nil when it cannot run or takes longer than `signTimeout` (a locked keychain or a
    /// stuck preferences daemon must not stall every report).
    private func bounded(_ command: ProcessCommand) async -> ProcessOutcome? {
        let runner = runner, clock = clock, timeout = signTimeout
        return await withTaskGroup(of: ProcessOutcome?.self) { group in
            group.addTask { try? await runner.run(command, onLine: { _ in }) }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private final class SimulatorListCache: Sendable {
    private let state = Mutex<(runtimes: [String], attemptedAt: Date?)>(([], nil))

    func withLock<R: Sendable>(_ body: (inout (runtimes: [String], attemptedAt: Date?)) -> R) -> R {
        state.withLock { body(&$0) }
    }
}
