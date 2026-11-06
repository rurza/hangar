import HangarWorker
import Testing

/// The commands the worker prints work as typed by an administrator, whoever the worker runs as.
@Suite struct WorkerCommandLineTests {
    @Test func theHangarUsersCommandsGoThroughSudo() {
        let line = WorkerCommandLine(binary: "/Users/hangar/.local/bin/hangar-worker", user: "hangar")
        #expect(line.asRoot("vm", "network", "install") == "sudo /Users/hangar/.local/bin/hangar-worker vm network install")
        #expect(line.asWorker("vm", "image", "build") == "sudo -u hangar -H /Users/hangar/.local/bin/hangar-worker vm image build")
        #expect(line.vmSetup == "sudo /Users/hangar/.local/bin/hangar-worker vm setup")
    }

    @Test func anOwnerRunWorkerIsTypedByItsPath() {
        let line = WorkerCommandLine(binary: "/Users/adam/.local/bin/hangar-worker", user: "adam")
        #expect(line.asWorker("vm", "image", "build") == "/Users/adam/.local/bin/hangar-worker vm image build")
        #expect(line.vmSetup == "sudo /Users/adam/.local/bin/hangar-worker vm setup")
    }

    @Test func aPathWithASpaceIsQuoted() {
        let line = WorkerCommandLine(binary: "/Users/a b/bin/hangar-worker", user: "a")
        #expect(line.asWorker("vm", "status") == "'/Users/a b/bin/hangar-worker' vm status")
    }
}
