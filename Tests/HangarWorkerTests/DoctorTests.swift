import Clocks
import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarWorker

@Suite(.timeLimit(.minutes(1))) struct DoctorTests {
    static let identityLine =
        "  1) 0123456789ABCDEF0123456789ABCDEF01234567 \"Apple Development: Adam (TEAM123456)\""

    static func scriptedRunner(
        battery: [String] = [
            "Now drawing from 'AC Power'", " -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true",
        ]
    ) -> RecordingProcessRunner {
        let runner = RecordingProcessRunner()
        runner.script({ $0.arguments == ["-productVersion"] }, lines: ["26.1"])
        runner.script({ $0.arguments == ["-n", "machdep.cpu.brand_string"] }, lines: ["Apple M4 Pro"])
        runner.script({ $0.arguments == ["-n", "hw.perflevel0.physicalcpu"] }, lines: ["10"])
        runner.script({ $0.arguments == ["-n", "hw.memsize"] }, lines: ["17179869184"])
        runner.script({ $0.executable.hasSuffix("pmset") }, lines: battery)
        return runner
    }

    static func doctor(
        _ runner: any ProcessRunner, tools: [String] = [], clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) -> Doctor {
        Doctor(
            runner: runner, locator: XcodeLocator(runner: RecordingProcessRunner(), applicationsDirectory: "/nonexistent"),
            knownTools: tools, dataDirectory: NSTemporaryDirectory(), clock: clock, now: now)
    }

    static func isSimctl(_ command: ProcessCommand) -> Bool { command.arguments.starts(with: ["simctl"]) }

    /// Answers from `good` until `failing` is set, then from `bad`.
    final class SwitchingRunner: ProcessRunner {
        let good = DoctorTests.scriptedRunner()
        let bad = DoctorTests.scriptedRunner()
        let failing = Mutex(false)
        func run(_ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessOutcome {
            try await (failing.withLock { $0 } ? bad : good).run(command, onLine: onLine)
        }
        var simctlRuns: Int { (good.commands + bad.commands).filter(DoctorTests.isSimctl).count }
    }

    @Test func parsesSysctlAndPower() async {
        let report = await Self.doctor(Self.scriptedRunner()).report(runningJobIDs: [])
        #expect(report.macOSVersion == "26.1")
        #expect(report.chip == "Apple M4 Pro")
        #expect(report.performanceCores == 10)
        #expect(report.memoryGB == 16)
        #expect(report.onACPower)
        #expect(report.freeDiskGB > 0)
    }

    @Test func batteryDischargingIsNotAC() async {
        let runner = Self.scriptedRunner(battery: [
            "Now drawing from 'Battery Power'", " -InternalBattery-0 87%; discharging",
        ])
        #expect(await Self.doctor(runner).report(runningJobIDs: []).onACPower == false)
    }

    @Test func desktopWithoutBatteryCountsAsAC() async {
        let runner = Self.scriptedRunner(battery: [])
        #expect(await Self.doctor(runner).report(runningJobIDs: []).onACPower)
    }

    @Test func reportsSimulatorRuntimes() async throws {
        let runner = Self.scriptedRunner()
        let devices = String(decoding: SimulatorCatalogTests.several, as: UTF8.self)
        runner.script({ $0.arguments == ["simctl", "list", "devices", "available", "--json"] }, lines: [devices])
        let report = await Self.doctor(runner).report(runningJobIDs: [])
        #expect(report.simulatorRuntimes == ["iOS 26.4", "iOS 27.2", "visionOS 27.1"])
        #expect(report.capabilities == [WorkerCapability.testActions])
        #expect(runner.commands.first(where: Self.isSimctl)?.discardsStandardError == true)
        #expect(await Self.doctor(Self.scriptedRunner()).report(runningJobIDs: []).simulatorRuntimes == [])
    }

    @Test func simulatorRuntimesAreCachedAndTheLastGoodListSurvivesAFailure() async {
        let runner = SwitchingRunner()
        let devices = String(decoding: SimulatorCatalogTests.several, as: UTF8.self)
        runner.good.script(Self.isSimctl, lines: [devices])
        runner.bad.script(Self.isSimctl, lines: ["CoreSimulatorService connection became invalid"], exitCode: 1)
        let time = Mutex(Date(timeIntervalSince1970: 0))
        let doctor = Self.doctor(runner, now: { time.withLock { $0 } })
        let expected = ["iOS 26.4", "iOS 27.2", "visionOS 27.1"]

        #expect(await doctor.report(runningJobIDs: []).simulatorRuntimes == expected)
        time.withLock { $0 += 9 * 60 }
        #expect(await doctor.report(runningJobIDs: []).simulatorRuntimes == expected)
        #expect(runner.simctlRuns == 1)

        runner.failing.withLock { $0 = true }
        time.withLock { $0 += 2 * 60 }
        #expect(await doctor.report(runningJobIDs: []).simulatorRuntimes == expected)
        #expect(runner.simctlRuns == 2)
        // A failed probe is not retried on every heartbeat either.
        _ = await doctor.report(runningJobIDs: [])
        #expect(runner.simctlRuns == 2)
    }

    @Test func aHangingSimctlIsCutOff() async {
        let runner = Self.scriptedRunner()
        runner.scriptHang(Self.isSimctl)
        let clock = TestClock()
        let doctor = Self.doctor(runner, clock: clock)
        let finished = Mutex(false)
        let task = Task {
            let report = await doctor.report(runningJobIDs: [])
            finished.withLock { $0 = true }
            return report
        }
        while !finished.withLock({ $0 }) {
            await Task.yield()
            await clock.advance(by: .seconds(10))
        }
        #expect(await task.value.simulatorRuntimes == [])
    }

    @Test func runningJobsAreEchoed() async {
        let ids = [UUID(), UUID()]
        #expect(await Self.doctor(Self.scriptedRunner()).report(runningJobIDs: ids).runningJobIDs == ids)
    }

    @Test func reportsTheUserTheWorkerRunsAs() async {
        let doctor = Doctor(
            runner: Self.scriptedRunner(),
            locator: XcodeLocator(runner: RecordingProcessRunner(), applicationsDirectory: "/nonexistent"),
            knownTools: [], dataDirectory: NSTemporaryDirectory(), userName: "someone")
        #expect(await doctor.report(runningJobIDs: []).runningUser == "someone")
        #expect(await Self.doctor(Self.scriptedRunner()).report(runningJobIDs: []).runningUser == NSUserName())
    }

    @Test func failedProbesFallBackToConservativeDefaults() async {
        let runner = RecordingProcessRunner()
        runner.script({ _ in true }, lines: ["boom"], exitCode: 1)
        let report = await Self.doctor(runner).report(runningJobIDs: [])
        #expect(report.performanceCores == 0)
        #expect(report.memoryGB == 0)
        #expect(report.macOSVersion == "")
        #expect(report.tools.isEmpty)
        #expect(report.canSignWithoutPrompt == false)
    }

    @Test func canSignFalseWhenNoIdentity() async {
        let runner = Self.scriptedRunner()
        runner.script({ $0.executable.hasSuffix("security") }, lines: ["     0 valid identities found"])
        let report = await Self.doctor(runner).report(runningJobIDs: [])
        #expect(report.canSignWithoutPrompt == false)
        #expect(!runner.commands.contains { $0.executable.hasSuffix("codesign") })
    }

    @Test func canSignTrueWhenCodesignSucceedsWithTheIdentityHash() async {
        let runner = Self.scriptedRunner()
        runner.script(
            { $0.executable.hasSuffix("security") },
            lines: [
                "  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \"Developer ID Application: Someone (X)\"",
                Self.identityLine, "     2 valid identities found",
            ])
        let report = await Self.doctor(runner).report(runningJobIDs: [])
        #expect(report.canSignWithoutPrompt)
        let sign = runner.commands.first { $0.executable.hasSuffix("codesign") }
        #expect(sign?.arguments.prefix(3) == ["--force", "--sign", "0123456789ABCDEF0123456789ABCDEF01234567"])
        let target = sign?.arguments.last ?? ""
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func canSignFalseWhenCodesignFails() async {
        let runner = Self.scriptedRunner()
        runner.script({ $0.executable.hasSuffix("security") }, lines: [Self.identityLine])
        runner.script({ $0.executable.hasSuffix("codesign") }, lines: ["errSecInternalComponent"], exitCode: 1)
        #expect(await Self.doctor(runner).report(runningJobIDs: []).canSignWithoutPrompt == false)
    }

    // MARK: Local builds

    static func isFindIdentity(_ command: ProcessCommand) -> Bool { command.arguments.first == "find-identity" }

    /// A local worker signs with the owner's login keychain: nothing is unlocked or changed, it is only probed.
    @Test func aLocalWorkerOnlyProbesTheLoginKeychain() async throws {
        let runner = Self.scriptedRunner()
        runner.script(Self.isFindIdentity, lines: [Self.identityLine])
        let report = await Self.doctor(runner).report(runningJobIDs: [])
        #expect(report.canSignWithoutPrompt)
        #expect(!runner.commands.contains { $0.standardInput != nil })
        let json = String(decoding: try JSONCoding.encoder.encode(report), as: UTF8.self)
        #expect(!json.contains("headless") && !json.contains("keychainProblem"))
    }

    @Test func canSignFalseWhenCodesignTimesOut() async {
        let runner = Self.scriptedRunner()
        runner.script({ $0.executable.hasSuffix("security") }, lines: [Self.identityLine])
        runner.scriptHang { $0.executable.hasSuffix("codesign") }
        let clock = TestClock()
        let doctor = Self.doctor(runner, clock: clock)

        let finished = Mutex(false)
        let task = Task {
            let report = await doctor.report(runningJobIDs: [])
            finished.withLock { $0 = true }
            return report
        }
        // Advance until the sign probe has registered its timeout sleep and the race resolves.
        while !finished.withLock({ $0 }) {
            await Task.yield()
            await clock.advance(by: .seconds(10))
        }
        #expect(await task.value.canSignWithoutPrompt == false)
        let target = runner.commands.first { $0.executable.hasSuffix("codesign") }?.arguments.last ?? ""
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func toolsMapOnlyPresentOnes() async {
        let runner = Self.scriptedRunner()
        runner.script({ $0.arguments.last == "command -v git" }, lines: ["/usr/bin/git"])
        runner.script({ $0.arguments.last == "command -v brew" }, lines: [], exitCode: 1)
        let report = await Self.doctor(runner, tools: ["git", "brew", "bad;rm -rf"]).report(runningJobIDs: [])
        #expect(report.tools == ["git": "/usr/bin/git"])
        #expect(!runner.commands.contains { $0.arguments.last?.contains("rm -rf") == true })
    }

    @Test func reportsSigningIdentityNamesOnceEach() async {
        let runner = Self.scriptedRunner()
        runner.script(
            { $0.executable.hasSuffix("security") },
            lines: [
                Self.identityLine,
                "  2) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \"Developer ID Application: Someone (X)\"",
                "  3) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB \"Apple Development: Adam (TEAM123456)\"",
                "     3 valid identities found",
            ])
        let report = await Self.doctor(runner).report(runningJobIDs: [])
        #expect(report.signingIdentities == ["Apple Development: Adam (TEAM123456)", "Developer ID Application: Someone (X)"])
        #expect(runner.commands.filter { $0.executable.hasSuffix("security") }.count == 1)
    }

    @Test func xcodeAccountSignedInWhenXcodeListsAnAppleID() async {
        let runner = Self.scriptedRunner()
        runner.script(
            { $0.executable.hasSuffix("defaults") && $0.arguments.last == "DVTDeveloperAccountManagerAppleIDLists" },
            lines: ["{", "    \"IDE.Identifiers.Prod\" = (", "        { identifier = \"7E13918F\"; }", "    );", "}"])
        #expect(await Self.doctor(runner).report(runningJobIDs: []).xcodeAccountSignedIn == true)
    }

    @Test func xcodeAccountNotSignedInWhenXcodeHasNoAccounts() async {
        let runner = Self.scriptedRunner()
        runner.script(
            { $0.executable.hasSuffix("defaults") },
            lines: ["The domain/default pair of (com.apple.dt.Xcode, DVTDeveloperAccountManagerAppleIDLists) does not exist"],
            exitCode: 1)
        #expect(await Self.doctor(runner).report(runningJobIDs: []).xcodeAccountSignedIn == false)
        let empty = Self.scriptedRunner()
        empty.script({ $0.executable.hasSuffix("defaults") }, lines: ["{", "    \"IDE.Identifiers.Prod\" = (", "    );", "}"])
        #expect(await Self.doctor(empty).report(runningJobIDs: []).xcodeAccountSignedIn == false)
    }

    @Test func hangingSigningProbesTimeOut() async {
        let runner = Self.scriptedRunner()
        runner.scriptHang { $0.executable.hasSuffix("security") }
        runner.scriptHang { $0.executable.hasSuffix("defaults") }
        let clock = TestClock()
        let doctor = Self.doctor(runner, clock: clock)
        let finished = Mutex(false)
        let task = Task {
            let report = await doctor.report(runningJobIDs: [])
            finished.withLock { $0 = true }
            return report
        }
        while !finished.withLock({ $0 }) {
            await Task.yield()
            await clock.advance(by: .seconds(10))
        }
        let report = await task.value
        #expect(report.signingIdentities == [])
        #expect(report.xcodeAccountSignedIn == nil)
        #expect(report.canSignWithoutPrompt == false)
    }
}
