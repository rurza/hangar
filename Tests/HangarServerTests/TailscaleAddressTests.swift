import HangarCore
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
}
