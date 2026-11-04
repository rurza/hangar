import HangarCore
import Synchronization
import Testing

@testable import HangarServer

@Suite struct TailscaleAddressTests {
    private let appBinary = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    @Test func usesTheAppBinaryAndTakesTheFirstIPv4Line() async {
        let runner = RecordingProcessRunner()
        runner.script({ $0.executable == appBinary }, lines: ["100.64.1.2", "100.64.9.9"])
        #expect(await TailscaleAddress.detect(runner: runner) == "100.64.1.2")
        #expect(runner.commands.map(\.executable) == [appBinary])
        #expect(runner.commands[0].arguments == ["ip", "-4"])
    }

    @Test func fallsBackToTailscaleOnPath() async {
        let runner = RecordingProcessRunner()
        runner.script({ $0.executable == appBinary }, lines: ["no such file"], exitCode: 127)
        runner.script({ $0.executable == "tailscale" }, lines: ["100.100.1.1"])
        #expect(await TailscaleAddress.detect(runner: runner) == "100.100.1.1")
        #expect(runner.commands.map(\.executable) == [appBinary, "tailscale"])
    }

    @Test func returnsNilWhenBothFailOrPrintNoAddress() async {
        let failing = RecordingProcessRunner()
        failing.script({ _ in true }, lines: ["Tailscale is stopped."], exitCode: 1)
        #expect(await TailscaleAddress.detect(runner: failing) == nil)

        let garbage = RecordingProcessRunner()
        garbage.script({ _ in true }, lines: ["", "fd7a:115c::1", "not an ip"])
        #expect(await TailscaleAddress.detect(runner: garbage) == nil)
    }

    /// Fails the first `failures` `tailscale` calls (both candidates count), then prints an address.
    private final class FlakyRunner: ProcessRunner {
        private let calls = Mutex(0)
        let failures: Int
        init(failures: Int) { self.failures = failures }
        var callCount: Int { calls.withLock { $0 } }
        func run(_ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessOutcome {
            let n = calls.withLock { n -> Int in n += 1; return n }
            return n <= failures
                ? ProcessOutcome(exitCode: 1, output: "stopped") : ProcessOutcome(exitCode: 0, output: "100.64.0.7")
        }
    }

    @Test func waitSucceedsAfterARetry() async {
        let runner = FlakyRunner(failures: 4)  // two rounds of two candidates
        let address = await TailscaleAddress.waitForAddress(
            runner: runner, timeout: .seconds(2), interval: .milliseconds(5))
        #expect(address == "100.64.0.7")
        #expect(runner.callCount == 5)
    }

    @Test func waitGivesUpAfterTheTimeout() async {
        let runner = FlakyRunner(failures: .max)
        let address = await TailscaleAddress.waitForAddress(
            runner: runner, timeout: .milliseconds(40), interval: .milliseconds(10))
        #expect(address == nil)
        #expect(runner.callCount >= 2)
    }
}
