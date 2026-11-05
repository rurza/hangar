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
        _ runner: RecordingProcessRunner, tools: [String] = [], clock: any Clock<Duration> = ContinuousClock()
    ) -> Doctor {
        Doctor(
            runner: runner, locator: XcodeLocator(runner: runner, applicationsDirectory: "/nonexistent"),
            knownTools: tools, dataDirectory: NSTemporaryDirectory(), clock: clock)
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
        #expect(await Self.doctor(Self.scriptedRunner()).report(runningJobIDs: []).simulatorRuntimes == [])
    }

    @Test func runningJobsAreEchoed() async {
        let ids = [UUID(), UUID()]
        #expect(await Self.doctor(Self.scriptedRunner()).report(runningJobIDs: ids).runningJobIDs == ids)
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
}
