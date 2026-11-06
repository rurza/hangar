import HangarWorker
import Testing

/// The commands the worker prints work as typed by the Mac's owner, who runs the worker.
@Suite struct WorkerCommandLineTests {
    @Test func theWorkersCommandsAreTypedByItsPathAndRootsGoThroughSudo() {
        let line = WorkerCommandLine(binary: "/Users/adam/.local/bin/hangar-worker")
        #expect(line.asRoot("vm", "network", "install") == "sudo /Users/adam/.local/bin/hangar-worker vm network install")
        #expect(line.asWorker("vm", "image", "build") == "/Users/adam/.local/bin/hangar-worker vm image build")
        #expect(line.vmSetup == "sudo /Users/adam/.local/bin/hangar-worker vm setup")
    }

    @Test func aPathWithASpaceIsQuoted() {
        let line = WorkerCommandLine(binary: "/Users/a b/bin/hangar-worker")
        #expect(line.asWorker("vm", "status") == "'/Users/a b/bin/hangar-worker' vm status")
    }
}
