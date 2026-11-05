import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarWorker

@Suite(.timeLimit(.minutes(1))) struct VMLauncherTests {
    static func launcher(_ fixture: VMFixture, _ engine: FakeEngine, runner: RecordingProcessRunner = RecordingProcessRunner())
        -> VMLauncher
    {
        var launcher = VMLauncher(host: fixture.host(engine, runner: runner))
        launcher.pollInterval = .milliseconds(10)
        return launcher
    }

    @Test func aJobRestoresItsSlotsSavedStateOntoAClone() async throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        try fixture.saveSlot(0)
        let engine = FakeEngine()
        let job = fixture.storage.job(UUID())
        let vm = try await Self.launcher(fixture, engine).bootJob(image: try fixture.image(), slot: 0, job: job, user: "builder")

        let machine = try #require(engine.machines.first)
        let slot = try fixture.image().directory.slot(0)
        #expect(machine.calls == [.restore(slot.state)])
        #expect(machine.spec.disk == job.disk && machine.spec.nvram == job.nvram && machine.spec.share == job.share)
        #expect(machine.spec.macAddress == VMMACAddress.forSlot(0, machine: fixture.machineName))
        #expect(machine.spec.machineIdentifier == Data("slot-0".utf8))
        #expect(FileManager.default.contents(atPath: job.disk) == Data("slot".utf8))
        #expect(vm.address == "192.168.64.10")
        #expect(vm.note.hasPrefix("restored slot 0's saved state in "))
        #expect(!vm.slotIsStale)
    }

    @Test func aStateThatNoLongerRestoresFallsBackToAColdBootOfTheImage() async throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        try fixture.saveSlot(0)
        let engine = FakeEngine(restoreErrors: [.stateIncompatible("invalid argument")])
        let job = fixture.storage.job(UUID())
        let vm = try await Self.launcher(fixture, engine).bootJob(image: try fixture.image(), slot: 0, job: job, user: "builder")

        #expect(engine.machines.map(\.calls) == [[.restore(try fixture.image().directory.slot(0).state), .stop], [.start]])
        #expect(FileManager.default.contents(atPath: job.disk) == Data("disk".utf8))
        // The slot keeps its identity; its useless state is gone and it is saved again later.
        #expect(engine.machines[1].spec.macAddress == VMMACAddress.forSlot(0, machine: fixture.machineName))
        #expect(!FileManager.default.fileExists(atPath: try fixture.image().directory.slot(0).state))
        #expect(vm.slotIsStale)
        #expect(vm.note.contains("cold-booted") && vm.note.contains("did not restore"))
    }

    @Test func noStateOrAStaleOneColdBoots() async throws {
        for stale in [false, true] {
            let fixture = try VMFixture()
            defer { fixture.cleanUp() }
            if stale { try fixture.saveSlot(0, memoryGB: 4) }
            let engine = FakeEngine()
            let vm = try await Self.launcher(fixture, engine).bootJob(
                image: try fixture.image(), slot: 0, job: fixture.storage.job(UUID()), user: "builder")
            #expect(engine.machines.map(\.calls) == [[.start]])
            #expect(engine.machines[0].spec.memoryBytes == 8 << 30)
            #expect(vm.note.contains(stale ? "CPUs or memory changed" : "no saved state"))
            #expect(vm.slotIsStale)
        }
    }

    @Test func aBootThatNeverAnswersSSHStopsTheVM() async throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        let runner = RecordingProcessRunner()
        runner.script({ $0.executable == "/usr/bin/ssh" }, lines: [], exitCode: 255)
        var launcher = Self.launcher(fixture, FakeEngine(), runner: runner)
        launcher.bootDeadline = .milliseconds(200)
        let engine = launcher.host.engine as! FakeEngine
        await #expect(throws: VMError.self) {
            try await launcher.bootJob(image: try fixture.image(), slot: 0, job: fixture.storage.job(UUID()), user: "builder")
        }
        #expect(engine.machines.first?.calls == [.start, .stop])
    }

    @Test func preparingASlotGivesItItsOwnIdentityAndSavesItsState() async throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        let runner = RecordingProcessRunner()
        runner.script({ $0.arguments.last?.contains("vm.loadavg") == true }, lines: ["builder", "{ 0.12 0.30 0.50 }"])
        let engine = FakeEngine()
        var launcher = Self.launcher(fixture, engine, runner: runner)
        launcher.host.clock = ImmediateClock()
        let image = try fixture.image()
        try await launcher.prepareSlot(image: image, slot: 1)

        let slot = image.directory.slot(1)
        #expect(engine.machines.first?.calls == [.start, .save(slot.state), .stop])
        let metadata = try VMBundleFile.read(VMSlotMetadata.self, at: slot.metadata)
        #expect(metadata.macAddress == VMMACAddress.forSlot(1, machine: fixture.machineName))
        #expect(metadata.imageID == image.metadata.id && metadata.hostBuild == "25G83")
        #expect(metadata.cpus == 4 && metadata.memoryGB == 8)
        #expect(engine.machines[0].spec.share == slot.share)
        #expect(FileManager.default.fileExists(atPath: slot.disk) && FileManager.default.fileExists(atPath: slot.state))
        #expect(VMDoctor.slotState(image: image, slot: 1, host: launcher.host).hasPrefix("saved "))
    }

    @Test func theLoadAverageReads() {
        #expect(VMLauncher.oneMinuteLoad("{ 0.52 0.61 0.80 }") == 0.52)
        #expect(VMLauncher.oneMinuteLoad("garbage") == nil)
    }
}

/// A clock whose sleeps return at once (only the real elapsed time advances).
struct ImmediateClock: Clock {
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

@Suite(.timeLimit(.minutes(1))) struct VMJobRunnerTests {
    struct Setup {
        let fixture: VMFixture
        let engine = FakeEngine()
        let runner = RecordingProcessRunner()
        let connection = FakeTokenConnection()
        let launcher: FakeSessionLauncher
        let identity: VMIdentityStore
        let pool = VMSlotPool(count: 1)

        init(identity withIdentity: Bool = true, saved: Bool = true, script: @escaping @Sendable (FakeGuestSession, String) -> Void) throws {
            fixture = try VMFixture()
            if saved { try fixture.saveSlot(0) }
            launcher = FakeSessionLauncher(script: script)
            identity = VMIdentityStore(dataDirectory: fixture.root)
            if withIdentity { try identity.save(p12: Data("p12".utf8), password: SensitiveText("pw")) }
        }

        func jobRunner(
            readiness: @escaping @Sendable () -> String? = { nil }, grace: Duration = .seconds(5), timeout: Duration? = nil
        ) -> VMJobRunner {
            var launcherConfig = VMLauncher(host: fixture.host(engine, runner: runner))
            launcherConfig.pollInterval = .milliseconds(10)
            var jobRunner = VMJobRunner(
                launcher: launcherConfig, connection: connection, serverURL: URL(string: "http://mini:8787")!,
                identity: identity, slots: pool, workerBinary: "/usr/local/bin/hangar-worker", sessions: launcher,
                readiness: readiness, cancelGrace: grace)
            if let timeout { jobRunner.jobTimeout = timeout }
            return jobRunner
        }

        var jobDirectories: [String] { (try? FileManager.default.contentsOfDirectory(atPath: fixture.storage.jobs)) ?? [] }
    }

    /// Answers the bundle with a result line, as `run-job` does.
    static func succeeding(_ session: FakeGuestSession, _ line: String) {
        guard line.hasPrefix("{") else { return }
        session.print("guest log line")
        session.print(GuestJobRunner.resultLine(JobResult(status: .succeeded, outputs: ["k": "v"])))
        session.end(0)
    }

    @Test func aJobRunsInItsVMWithAOneJobTokenAndTheCloneIsGoneAfterwards() async throws {
        let setup = try Setup(script: Self.succeeding)
        defer { setup.fixture.cleanUp() }
        let assignment = WorkerLoopTests.assignment()
        let result = await setup.jobRunner().run(assignment, cancelled: { false }, stopReason: { nil })

        #expect(result == JobResult(status: .succeeded, outputs: ["k": "v"]))
        #expect(setup.connection.issued == [assignment.job.id])
        #expect(setup.connection.revoked == [assignment.job.id])
        // The guest reported its own result; the host did not finish the job on top of it.
        #expect(setup.connection.base.result == nil)
        #expect(setup.engine.machines.first?.calls.last == .stop)
        #expect(setup.jobDirectories.isEmpty)
        #expect(setup.pool.freeCount == 1)

        let session = try #require(setup.launcher.commands.first)
        #expect(session.arguments.contains("-R"))
        #expect(session.arguments.contains { $0.hasPrefix("127.0.0.1:8787:127.0.0.1:") })
        #expect(session.arguments.suffix(3) == ["builder@192.168.64.10", "--", "./.hangar/bin/hangar-worker vm run-job"])
        #expect(!session.arguments.joined().contains("hgj_job-token"))

        let bundleLine = try #require(setup.launcher.sessions.first?.sent.first)
        let bundle = try JSONCoding.decoder.decode(GuestJobBundle.self, from: Data(bundleLine.utf8))
        #expect(bundle.token == "hgj_job-token")
        #expect(bundle.assignment == assignment)
        #expect(bundle.serverURL == URL(string: "http://127.0.0.1:8787")!)
        #expect(bundle.identity == GuestIdentity(p12: Data("p12".utf8), password: "pw"))
        #expect(bundle.vmNote?.hasPrefix("VM: restored slot 0's saved state") == true)
        #expect(bundle.machineName == "test-mac (VM)")

        // Handed over as admin (name, clock, entropy on standard input), then the worker binary copied in.
        let commands = setup.runner.commands
        let handOver = try #require(commands.first { $0.arguments.last?.contains("scutil --set ComputerName test-mac-vm0") == true })
        #expect(handOver.arguments.contains("admin@192.168.64.10"))
        #expect(handOver.standardInput != nil)
        #expect(commands.contains { $0.executable == "/bin/sh" && $0.arguments[1].contains("< /usr/local/bin/hangar-worker") })
    }

    @Test func aCancelledJobTellsTheGuestWhichReportsItself() async throws {
        let setup = try Setup { session, line in
            if line.hasPrefix("cancel") {
                session.print(GuestJobRunner.resultLine(JobResult(status: .cancelled)))
                session.end(0)
            }
        }
        defer { setup.fixture.cleanUp() }
        let result = await setup.jobRunner().run(WorkerLoopTests.assignment(), cancelled: { true }, stopReason: { nil })
        #expect(result.status == .cancelled)
        #expect(setup.launcher.sessions.first?.sent.last == "cancel")
        #expect(setup.jobDirectories.isEmpty)
    }

    @Test func aGuestThatIgnoresTheCancelIsStoppedAndTheHostReportsIt() async throws {
        let setup = try Setup { _, _ in }
        defer { setup.fixture.cleanUp() }
        let result = await setup.jobRunner(grace: .milliseconds(100)).run(
            WorkerLoopTests.assignment(), cancelled: { true }, stopReason: { "hangar-worker on test-mac was stopped (SIGTERM)" })
        #expect(result == JobResult(status: .cancelled, failureReason: "hangar-worker on test-mac was stopped (SIGTERM)"))
        #expect(setup.connection.base.result == result)
        #expect(setup.launcher.sessions.first?.wasTerminated == true)
        #expect(setup.engine.machines.first?.calls.last == .stop)
        #expect(setup.connection.revoked.count == 1)
    }

    @Test func aJobPastItsTimeoutIsCancelledWithTheReason() async throws {
        let setup = try Setup { session, line in
            if line.hasPrefix("cancel ") {
                session.print(GuestJobRunner.resultLine(JobResult(status: .cancelled, failureReason: String(line.dropFirst(7)))))
                session.end(0)
            }
        }
        defer { setup.fixture.cleanUp() }
        let result = await setup.jobRunner(timeout: .milliseconds(50)).run(
            WorkerLoopTests.assignment(), cancelled: { false }, stopReason: { nil })
        #expect(result.status == .cancelled)
        #expect(result.failureReason?.contains("VM job timeout on test-mac") == true)
    }

    @Test func aVMThatStopsMidJobFailsIt() async throws {
        let setup = try Setup { _, line in
            guard line.hasPrefix("{") else { return }
        }
        defer { setup.fixture.cleanUp() }
        let engine = setup.engine
        let task = Task { await setup.jobRunner().run(WorkerLoopTests.assignment(), cancelled: { false }, stopReason: { nil }) }
        while setup.launcher.sessions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        engine.machines.first?.stopOnItsOwn(.error("Internal Virtualization error"))
        let result = await task.value
        #expect(result.status == .failed)
        #expect(result.failureReason == "the build VM stopped: Internal Virtualization error")
        #expect(setup.connection.base.result == result)
        #expect(setup.jobDirectories.isEmpty)
    }

    @Test func aGuestThatExitsWithoutAResultFailsTheJob() async throws {
        let setup = try Setup { session, line in if line.hasPrefix("{") { session.end(255) } }
        defer { setup.fixture.cleanUp() }
        let result = await setup.jobRunner().run(WorkerLoopTests.assignment(), cancelled: { false }, stopReason: { nil })
        #expect(result.failureReason == "the build VM stopped responding (SSH dropped)")
    }

    @Test func aVMThatDoesNotBootFailsTheJobAndCleansUp() async throws {
        let setup = try Setup(saved: false, script: Self.succeeding)
        defer { setup.fixture.cleanUp() }
        setup.runner.script({ $0.executable == "/usr/bin/ssh" }, lines: [], exitCode: 255)
        // The cold boot never answers SSH: shorten the wait through a launcher with a tiny deadline.
        var launcher = VMLauncher(host: setup.fixture.host(setup.engine, runner: setup.runner))
        launcher.bootDeadline = .milliseconds(100)
        launcher.pollInterval = .milliseconds(10)
        let quick = VMJobRunner(
            launcher: launcher, connection: setup.connection, serverURL: URL(string: "http://mini:8787")!,
            identity: setup.identity, slots: setup.pool, workerBinary: "/bin/true", sessions: setup.launcher,
            cancelGrace: .seconds(1))
        let result = await quick.run(WorkerLoopTests.assignment(), cancelled: { false }, stopReason: { nil })
        #expect(result.status == .failed)
        #expect(result.failureReason?.hasPrefix("could not start the build VM on test-mac: the VM did not answer SSH") == true)
        #expect(setup.connection.base.result == result)
        #expect(setup.connection.revoked.count == 1)
        #expect(setup.jobDirectories.isEmpty)
        #expect(setup.launcher.sessions.isEmpty)
        #expect(setup.pool.freeCount == 1)
    }

    /// The server's identity comes in the assignment and goes to the guest in the bundle, not in the bundle's copy of
    /// the assignment; a worker's own identity overrides it.
    @Test func theServersIdentityReachesTheGuestUnlessTheWorkerHasItsOwn() async throws {
        let server = JobSigningIdentity(p12: Data("server-p12".utf8), password: "server-pw")
        var assignment = WorkerLoopTests.assignment()
        assignment.signingIdentity = server
        var expected = assignment
        expected.signingIdentity = nil

        let plain = try Setup(identity: false, script: Self.succeeding)
        defer { plain.fixture.cleanUp() }
        #expect(await plain.jobRunner().run(assignment, cancelled: { false }, stopReason: { nil }).status == .succeeded)
        let line = try #require(plain.launcher.sessions.first?.sent.first)
        let bundle = try JSONCoding.decoder.decode(GuestJobBundle.self, from: Data(line.utf8))
        #expect(bundle.identity == GuestIdentity(p12: server.p12, password: server.password))
        #expect(bundle.assignment == expected)
        #expect(bundle.assignment.signingIdentity == nil)

        let overridden = try Setup(identity: true, script: Self.succeeding)
        defer { overridden.fixture.cleanUp() }
        #expect(await overridden.jobRunner().run(assignment, cancelled: { false }, stopReason: { nil }).status == .succeeded)
        let other = try #require(overridden.launcher.sessions.first?.sent.first)
        let overriddenBundle = try JSONCoding.decoder.decode(GuestJobBundle.self, from: Data(other.utf8))
        #expect(overriddenBundle.identity == GuestIdentity(p12: Data("p12".utf8), password: "pw"))
    }

    @Test func nothingStartsWhenVMBuildsAreNotReadyOrTheImageOrIdentityIsMissing() async throws {
        let setup = try Setup(identity: false, script: Self.succeeding)
        defer { setup.fixture.cleanUp() }
        var result = await setup.jobRunner(readiness: { "the VM network filter is not installed" }).run(
            WorkerLoopTests.assignment(), cancelled: { false }, stopReason: { nil })
        #expect(result.failureReason == "VM builds are not ready on test-mac: the VM network filter is not installed")

        var assignment = WorkerLoopTests.assignment()
        assignment.workflow.xcode = "28.0"
        result = await setup.jobRunner().run(assignment, cancelled: { false }, stopReason: { nil })
        #expect(result.failureReason?.contains("no VM image with Xcode 28.0") == true)

        // An archive needs a development identity (the server's, or this worker's own): without one a fresh VM would
        // create a certificate.
        result = await setup.jobRunner().run(WorkerLoopTests.assignment(), cancelled: { false }, stopReason: { nil })
        #expect(result.failureReason?.contains("Settings › Signing") == true)
        #expect(setup.connection.issued.isEmpty)
        #expect(setup.engine.machines.isEmpty)
    }

    @Test func aStaleSlotIsSavedAgainAfterTheJob() async throws {
        let setup = try Setup(saved: false, script: Self.succeeding)
        defer { setup.fixture.cleanUp() }
        setup.runner.script({ $0.arguments.last?.contains("vm.loadavg") == true }, lines: ["builder", "{ 0.10 0.10 0.10 }"])
        var launcher = VMLauncher(host: setup.fixture.host(setup.engine, runner: setup.runner))
        launcher.pollInterval = .milliseconds(10)
        launcher.host.clock = ImmediateClock()
        let jobRunner = VMJobRunner(
            launcher: launcher, connection: setup.connection, serverURL: URL(string: "http://mini:8787")!,
            identity: setup.identity, slots: setup.pool, workerBinary: "/bin/true", sessions: setup.launcher,
            cancelGrace: .seconds(1))
        let result = await jobRunner.run(WorkerLoopTests.assignment(), cancelled: { false }, stopReason: { nil })
        #expect(result.status == .succeeded)
        #expect(setup.engine.machines.count == 2)
        #expect(setup.engine.machines[1].calls.contains { if case .save = $0 { true } else { false } })
        #expect(FileManager.default.fileExists(atPath: try setup.fixture.image().directory.slot(0).state))
    }

    @Test func aMacAlreadyRunningTwoVMsMakesTheJobWaitNotFail() async throws {
        let setup = try Setup(saved: false, script: Self.succeeding)
        defer { setup.fixture.cleanUp() }
        let engine = FakeEngine(startErrors: [.tooManyVMs, .tooManyVMs])
        var launcher = VMLauncher(host: setup.fixture.host(engine, runner: setup.runner))
        launcher.pollInterval = .milliseconds(10)
        launcher.host.clock = ImmediateClock()
        var jobRunner = VMJobRunner(
            launcher: launcher, connection: setup.connection, serverURL: URL(string: "http://mini:8787")!,
            identity: setup.identity, slots: setup.pool, workerBinary: "/bin/true", sessions: setup.launcher,
            cancelGrace: .seconds(1))
        jobRunner.roomRetry = .milliseconds(10)
        let result = await jobRunner.run(WorkerLoopTests.assignment(), cancelled: { false }, stopReason: { nil })
        #expect(result.status == .succeeded)
        #expect(engine.machines.prefix(3).map { $0.calls.first } == [.start, .start, .start])
    }

    @Test func slotsAreTakenLowestFirstAndGivenBack() {
        let pool = VMSlotPool(count: 2)
        #expect(pool.acquire() == 0)
        #expect(pool.acquire(1))
        #expect(pool.acquire() == nil)
        #expect(!pool.acquire(1))
        pool.release(0)
        #expect(pool.freeCount == 1)
        #expect(pool.acquire() == 0)
    }

    @Test func guestNamesAreHostNames() {
        #expect(VMJobRunner.guestName(machine: "rurzobuk-max", slot: 1) == "rurzobuk-max-vm1")
        #expect(VMJobRunner.guestName(machine: "Adam's Mac mini", slot: 0) == "Adam-s-Mac-mini-vm0")
    }
}

@Suite(.timeLimit(.minutes(1))) struct VMDoctorTests {
    @Test func slotsAreReadyOnlyWithTheFilterAndAJobImage() throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        let host = fixture.host(FakeEngine())
        let identity = VMIdentityStore(dataDirectory: fixture.root)

        var doctor = VMDoctor(host: host, identity: identity, networkFilterProblem: { nil })
        var report = doctor.report(runningJobs: 0)
        #expect(report.slots == 1 && report.freeSlots == 1 && report.configuredSlots == 1)
        #expect(report.networkFilter && report.problem == nil)
        #expect(report.images == [VMImageInfo(name: "xcode-27.2", macOS: "26.6.2 (25G83)", xcode: "27.2", xcodeBuild: "17C52", simulatorRuntimes: ["iOS 27.2"])])
        #expect(doctor.report(runningJobs: 1).freeSlots == 0)

        doctor.networkFilterProblem = { "the VM network filter is not installed" }
        report = doctor.report(runningJobs: 0)
        #expect(report.slots == 0 && report.freeSlots == 0 && !report.networkFilter)
        #expect(report.problem == "the VM network filter is not installed")

        // No identity of its own is needed: the server sends its own. One the worker holds is reported as an override.
        #expect(!report.ownIdentity)
        try identity.save(p12: Data("p12".utf8), password: SensitiveText("pw"))
        #expect(doctor.report(runningJobs: 0).ownIdentity)
    }

    @Test func aBaseImageAloneIsNotEnough() throws {
        let fixture = try VMFixture(buildUser: nil, xcode: nil)
        defer { fixture.cleanUp() }
        let report = VMDoctor(host: fixture.host(FakeEngine()), identity: VMIdentityStore(dataDirectory: fixture.root),
            networkFilterProblem: { nil }).report(runningJobs: 0)
        #expect(report.slots == 0)
        #expect(report.problem?.contains("vm image build") == true)
        #expect(report.images.isEmpty)
    }

    @Test func aBinaryWithoutTheEntitlementReportsIt() throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        let report = VMDoctor(
            host: fixture.host(FakeEngine(unavailable: VMError.entitlementMissing.description)),
            identity: VMIdentityStore(dataDirectory: fixture.root), networkFilterProblem: { nil }
        ).report(runningJobs: 0)
        #expect(report.problem?.contains("com.apple.security.virtualization") == true)
    }

    @Test func maintenanceSweepsLeftoverClones() throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        try FileManager.default.createDirectory(atPath: fixture.storage.job(id).share, withIntermediateDirectories: true)
        #expect(VMMaintenance.sweep(storage: fixture.storage).contains("swept leftover VM clone \(id.uuidString)"))
    }

    @Test func theHostPicksTheImageWithTheRequestedXcode() throws {
        let fixture = try VMFixture()
        defer { fixture.cleanUp() }
        let host = fixture.host(FakeEngine())
        #expect(host.image(forXcode: "27.2")?.metadata.name == "xcode-27.2")
        #expect(host.image(forXcode: "27")?.metadata.name == "xcode-27.2")
        #expect(host.image(forXcode: "26.4") == nil)
    }
}
