import Foundation
import HangarAppStoreConnect
import HangarCore
import Logging
import Synchronization

/// Runs each job in a fresh VM (VM builds design, *Per-job lifecycle*): picks the image with the workflow's Xcode,
/// clones a free slot and restores its state (or cold-boots), hands the guest the job over SSH, relays its API calls
/// to the server with a one-job token, enforces the timeout, and deletes the clone however the job ends.
///
/// The guest runs the existing pipeline (`hangar-worker vm run-job`) and reports the job's start, steps, log,
/// artifacts and result itself. The host reports only a failure the guest could not: a VM that did not come up, a
/// guest that vanished, a timeout it did not answer.
///
/// An archive is split (`JobRunner+VM`): the guest archives with the development profiles the server provides and
/// hands off after `post-xcodebuild`; the host copies the archive out, deletes the VM, and runs the export and the
/// post-actions itself with the server's App Store Connect key, which never enters the guest.
public struct VMJobRunner: JobRunning {
    /// How long a cancelled guest gets to report its result before its VM is stopped anyway.
    public var cancelGrace: Duration = .seconds(60)
    /// A job still running after this is cancelled, then its VM stopped (`vm.jobTimeoutMinutes`).
    public var jobTimeout: Duration
    /// How long a job waits for a slot that is busy (its state being saved again) before it fails.
    public var slotWait: Duration = .seconds(900)
    /// How often a job whose VM could not start because two VMs already run tries again.
    public var roomRetry: Duration = .seconds(30)
    /// Finds this Mac's Xcode for a handed-off archive's export; nil for the default (`/Applications`).
    var hostLocator: XcodeLocator?
    /// The guest's end of the relay.
    public static let guestServerPort = 8787
    static let guestBinary = ".hangar/bin/hangar-worker"

    private let host: VMHost
    private let launcher: VMLauncher
    private let connection: any ServerConnection & JobTokenIssuing
    private let sessions: any GuestSessionLaunching
    private let slots: VMSlotPool
    private let identity: VMIdentityStore
    /// The worker binary copied into each guest: this process's own, so an image never needs rebuilding for an update.
    private let workerBinary: String
    private let serverURL: URL
    /// Nil when VM jobs may run; checked again before every job.
    private let readiness: @Sendable () -> String?
    private let appStoreConnectFactory: JobRunner.AppStoreConnectFactory
    private let logger = Logger(label: "app.hangar.worker.vm")

    public init(
        host: VMHost, connection: any ServerConnection & JobTokenIssuing, serverURL: URL, identity: VMIdentityStore,
        slots: VMSlotPool, workerBinary: String, sessions: any GuestSessionLaunching = LiveGuestSessionLauncher(),
        readiness: @escaping @Sendable () -> String? = { nil },
        appStoreConnectFactory: @escaping JobRunner.AppStoreConnectFactory = {
            LiveAppStoreConnectClient(credentials: $0, transport: URLSessionTransport())
        }
    ) {
        self.appStoreConnectFactory = appStoreConnectFactory
        self.host = host
        self.launcher = VMLauncher(host: host)
        self.connection = connection
        self.serverURL = serverURL
        self.identity = identity
        self.slots = slots
        self.workerBinary = workerBinary
        self.sessions = sessions
        self.readiness = readiness
        self.jobTimeout = .seconds(host.settings.jobTimeoutMinutes * 60)
    }

    init(
        launcher: VMLauncher, connection: any ServerConnection & JobTokenIssuing, serverURL: URL, identity: VMIdentityStore,
        slots: VMSlotPool, workerBinary: String, sessions: any GuestSessionLaunching,
        readiness: @escaping @Sendable () -> String? = { nil }, cancelGrace: Duration,
        appStoreConnectFactory: @escaping JobRunner.AppStoreConnectFactory = {
            LiveAppStoreConnectClient(credentials: $0, transport: URLSessionTransport())
        }
    ) {
        self.appStoreConnectFactory = appStoreConnectFactory
        self.host = launcher.host
        self.launcher = launcher
        self.connection = connection
        self.serverURL = serverURL
        self.identity = identity
        self.slots = slots
        self.workerBinary = workerBinary
        self.sessions = sessions
        self.readiness = readiness
        self.cancelGrace = cancelGrace
        self.jobTimeout = .seconds(launcher.host.settings.jobTimeoutMinutes * 60)
    }

    public func run(
        _ assignment: JobAssignment, cancelled: @escaping @Sendable () -> Bool,
        stopReason: @escaping @Sendable () -> String?
    ) async -> JobResult {
        let jobID = assignment.job.id
        let metadata: Logger.Metadata = ["job": "\(jobID)"]
        if let problem = readiness() { return await fail(jobID, "VM builds are not ready on \(host.machineName): \(problem)") }
        guard let image = host.image(forXcode: assignment.workflow.xcode) else {
            return await fail(jobID, "\(host.machineName) has no VM image with Xcode \(assignment.workflow.xcode): build one with `hangar-worker vm image build`")
        }
        let free = VMVolume.freeGB(at: host.storage.root)
        let needed = Double(host.settings.floorGB + host.settings.jobReserveGB)
        guard free >= needed else {
            return await fail(jobID, "only \(Int(free)) GB free for VMs on \(host.machineName) (needs \(Int(needed)) GB)")
        }
        // The server's identity comes in the assignment; this worker's own (`vm identity import`) overrides it.
        var assignment = assignment
        let serverIdentity = assignment.signingIdentity.map { GuestIdentity(p12: $0.p12, password: $0.password) }
        assignment.signingIdentity = nil
        let ownIdentity: GuestIdentity?
        do { ownIdentity = try identity.load() } catch {
            return await fail(jobID, "cannot read the VM signing identity on \(host.machineName): \(error)")
        }
        let guestIdentity = ownIdentity ?? serverIdentity
        if assignment.job.action.kind == .archive, guestIdentity == nil {
            return await fail(jobID, "Hangar sent no signing certificate for this VM archive: create or import one in Settings › Signing")
        }
        // The server's App Store Connect key stays on this host, for the export; the guest's copy has none. The guest
        // signs with the server's development profiles, or the development key only when one is missing.
        let hostAssignment = assignment
        assignment.appStoreConnectKey = nil
        var signing: JobRunner.GuestSigning?
        if assignment.job.action.kind == .archive {
            guard hostAssignment.appStoreConnectKey != nil else {
                return await fail(jobID, "Hangar sent no App Store Connect key for this archive's export: set it in Settings › App Store Connect")
            }
            do {
                let provisioning = try await connection.provisioning(
                    jobID: jobID, JobProvisioningRequest(useServerIdentity: ownIdentity == nil))
                if let problem = Self.signingProblem(provisioning, platform: assignment.job.action.platform) {
                    return await fail(jobID, problem)
                }
                signing = JobRunner.GuestSigning(
                    profiles: provisioning.profiles, developmentKey: provisioning.developmentKey,
                    missing: provisioning.missing, notes: provisioning.notes, teamID: provisioning.teamID)
            } catch {
                return await fail(jobID, "could not ask Hangar for this archive's development profiles: \(error)")
            }
        }
        // A slot can be held for a minute while its state is saved again; the job waits for it.
        var acquired = slots.acquire()
        let slotDeadline = ContinuousClock.now + slotWait
        while acquired == nil, ContinuousClock.now < slotDeadline, !cancelled() {
            try? await host.clock.sleep(for: .seconds(1))
            acquired = slots.acquire()
        }
        guard let slot = acquired else {
            if cancelled() { return await finish(jobID, JobResult(status: .cancelled, failureReason: stopReason())) }
            return await fail(jobID, "every VM slot on \(host.machineName) stayed busy for \(slotWait)")
        }
        let job = host.storage.job(jobID)
        var stale = false
        defer {
            // Synchronous parts only; the VM itself is stopped below on every path.
            try? SafeRemoval.removeItem(atPath: job.path, within: host.storage.jobs)
        }

        var token: String?
        var relay: GuestRelay?
        var machine: (any VirtualMachine)?
        let outcome: Outcome
        do {
            token = try await connection.issueJobToken(jobID: jobID)
            let rule = GuestRelay.Rule(jobID: jobID, token: token!)
            relay = try GuestRelay(rule: rule, server: serverURL)
            let port = try await relay!.start()
            let user = image.metadata.buildUser ?? "builder"
            let vm = try await bootWaitingForRoom(image: image, slot: slot, job: job, user: user, cancelled: cancelled)
            machine = vm.machine
            stale = vm.slotIsStale
            logger.info("job VM up at \(vm.address): \(vm.note)", metadata: metadata)
            try await handOver(to: vm, image: image, slot: slot, user: user)
            let ran = await runGuest(
                assignment, vm: vm, image: image, user: user, relayPort: port, token: token!, identity: guestIdentity,
                signing: signing, cancelled: cancelled, stopReason: stopReason)
            if case .handedOff(let handOff) = ran {
                // Copied out while the VM still runs; nothing of the guest's runs on this Mac.
                outcome = await collect(
                    handOff, from: vm, image: image, user: user, scheme: assignment.job.action.scheme,
                    projectDirectory: assignment.workflow.projectDirectory, into: hostRunner(job).layout(for: hostAssignment))
            } else {
                outcome = ran
            }
        } catch VMError.tooManyVMs {
            outcome = .hostFailure("\(host.machineName) already runs two macOS VMs (perhaps one of its owner's); the job could not get a slot")
        } catch {
            outcome = .hostFailure("could not start the build VM on \(host.machineName): \(error)")
        }

        await machine?.stop()
        relay?.stop()
        if token != nil {
            do { try await connection.revokeJobToken(jobID: jobID) } catch {
                logger.warning("could not revoke the job's token (it expires with the job): \(error)", metadata: metadata)
            }
        }
        let result: JobResult
        switch outcome {
        case .reported(let reported): result = reported
        case .hostFailure(let reason): result = await fail(jobID, reason)
        case .cancelled(let reason): result = await finish(jobID, JobResult(status: .cancelled, failureReason: reason))
        case .handedOff: result = await fail(jobID, "the build VM handed off its archive, but it was not copied out")
        case .exportOnHost(let abridged):
            logger.info("exporting the archive on this Mac", metadata: metadata)
            result = await hostRunner(job).runHostExport(
                hostAssignment, guestLogAbridged: abridged, cancelled: cancelled, stopReason: stopReason)
        }
        try? SafeRemoval.removeItem(atPath: job.path, within: host.storage.jobs)
        if stale, stopReason() == nil {
            logger.info("saving slot \(slot)'s state again", metadata: metadata)
            do { try await launcher.prepareSlot(image: image, slot: slot) } catch {
                logger.error("could not save slot \(slot)'s state: \(error); the next job cold-boots", metadata: metadata)
            }
        }
        slots.release(slot)
        return result
    }

    /// Boots the job's VM. While this Mac already runs two macOS VMs (one of them perhaps the owner's), the slot
    /// counts as busy: it tries again every `roomRetry` until `slotWait` has passed or the job is cancelled.
    func bootWaitingForRoom(
        image: VMImage, slot: Int, job: VMJobDirectory, user: String, cancelled: @Sendable () -> Bool
    ) async throws -> RunningVM {
        let deadline = ContinuousClock.now + slotWait
        while true {
            do {
                return try await launcher.bootJob(image: image, slot: slot, job: job, user: user)
            } catch VMError.tooManyVMs where ContinuousClock.now < deadline && !cancelled() {
                logger.notice("this Mac already runs two macOS VMs; trying again in \(roomRetry)", metadata: ["job": "\(job.path)"])
                for file in [job.disk, job.nvram] { try? FileManager.default.removeItem(atPath: file) }
                try await host.clock.sleep(for: roomRetry)
            }
        }
    }

    enum Outcome {
        /// The guest reported this result to the server itself.
        case reported(JobResult)
        /// The guest archived and handed off; its files are still in the VM.
        case handedOff(ArchiveHandOff)
        /// The guest's files are on this Mac: the host exports and reports.
        case exportOnHost(guestLogAbridged: Bool)
        /// The host reports this failure.
        case hostFailure(String)
        /// Cancelled, and the guest did not report it in time.
        case cancelled(String?)
    }

    /// As `admin`: the guest's name, its clock, and fresh entropy (every clone resumes with the same RNG state). Then
    /// the worker binary into the build user's home.
    func handOver(to vm: RunningVM, image: VMImage, slot: Int, user: String) async throws {
        let ssh = host.ssh(for: image.directory)
        let name = Self.guestName(machine: host.machineName, slot: slot)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMddHHmmyyyy.ss"
        var entropy = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy)
        let script = [
            "sudo -n scutil --set ComputerName \(GuestSSH.quote(name))",
            "sudo -n scutil --set LocalHostName \(GuestSSH.quote(name))",
            "sudo -n date -u \(formatter.string(from: Date())) >/dev/null",
            "base64 -d > /dev/random",
        ].joined(separator: " && ")
        try await ssh.require(
            "prepare the VM", user: "admin", host: vm.address, script,
            input: SensitiveText(Data(entropy).base64EncodedString() + "\n"))
        try await ssh.require("create the worker's directory", user: user, host: vm.address, "mkdir -p -m 0700 .hangar/bin")
        try await ssh.copy(file: workerBinary, user: user, host: vm.address, to: Self.guestBinary)
    }

    /// Runs a handed-off archive's export, post-actions, artifact upload and cleanup on this Mac, in the job's own
    /// directory (deleted with it), with the machine's connection. The export signs with the owner's login keychain.
    func hostRunner(_ job: VMJobDirectory) -> JobRunner {
        JobRunner(
            connection: connection, runner: host.runner, locator: hostLocator ?? XcodeLocator(runner: host.runner),
            dataDirectory: job.path + "/host", temporaryRoot: job.path + "/host-tmp", machineName: host.machineName,
            clock: host.clock, appStoreConnectFactory: appStoreConnectFactory)
    }

    /// Why an archive cannot start: a profile is missing and there is no development key. A macOS app that needs no
    /// profile signs with the certificate alone, so for macOS a missing one is only logged.
    static func signingProblem(_ provisioning: JobProvisioning, platform: Platform) -> String? {
        guard !provisioning.missing.isEmpty, provisioning.developmentKey == nil, platform != .macOS else { return nil }
        let reasons = provisioning.missing.map { "\($0.bundleID): \($0.reason)" }.joined(separator: "; ")
        return "Hangar has no development profile for this archive (\(reasons)), and no development key to let Xcode make one: fix that, or add a development key in Settings › App Store Connect"
    }

    /// Copies the guest's archive, result bundle, TestFlight notes and full log to `layout`. The paths come from the
    /// guest, so each must look like what it says it is before anything is copied.
    func collect(
        _ handOff: ArchiveHandOff, from vm: RunningVM, image: VMImage, user: String, scheme: String,
        projectDirectory: String, into layout: WorkspaceLayout
    ) async -> Outcome {
        func plausible(_ path: String, _ suffix: String) -> Bool {
            path.hasPrefix("/") && path.hasSuffix(suffix) && !path.split(separator: "/").contains("..")
        }
        guard plausible(handOff.archivePath, ".xcarchive"), plausible(handOff.resultBundlePath, ".xcresult"),
            plausible(handOff.testFlightDirectory, "/TestFlight"), plausible(handOff.fullLogPath, ".txt")
        else { return .hostFailure("the build VM handed off paths that are not an archive's") }
        let ssh = host.ssh(for: image.directory)
        let testFlight = layout.repository + (projectDirectory == "." ? "" : "/" + projectDirectory) + "/TestFlight"
        do {
            try FileManager.default.createDirectory(
                atPath: layout.jobDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard try await ssh.fetch(user: user, host: vm.address, remotePath: handOff.archivePath, to: layout.archive(scheme: scheme))
            else { return .hostFailure("the build VM handed off an archive it does not have") }
            for (remote, local) in [
                (handOff.resultBundlePath, layout.resultBundle), (handOff.testFlightDirectory, testFlight),
                (handOff.fullLogPath, layout.fullLog),
            ] {
                _ = try await ssh.fetch(user: user, host: vm.address, remotePath: remote, to: local)
            }
        } catch {
            return .hostFailure("could not copy the archive out of the build VM on \(host.machineName): \(error)")
        }
        return .exportOnHost(guestLogAbridged: handOff.fullLogAbridged)
    }

    /// "rurzobuk-max-vm0": a host name, so no spaces.
    static func guestName(machine: String, slot: Int) -> String {
        let base = machine.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        return String(base.prefix(50)) + "-vm\(slot)"
    }

    /// Starts `run-job` over SSH with the relay forwarded, sends the bundle, then watches for a cancel, the timeout
    /// and the VM stopping.
    func runGuest(
        _ assignment: JobAssignment, vm: RunningVM, image: VMImage, user: String, relayPort: UInt16, token: String,
        identity: GuestIdentity?, signing: JobRunner.GuestSigning? = nil, cancelled: @escaping @Sendable () -> Bool,
        stopReason: @escaping @Sendable () -> String?
    ) async -> Outcome {
        let jobID = assignment.job.id
        let ssh = host.ssh(for: image.directory)
        let command = ssh.command(
            user: user, host: vm.address, "./\(Self.guestBinary) vm run-job",
            extraOptions: ["-R", "127.0.0.1:\(Self.guestServerPort):127.0.0.1:\(relayPort)"])
        let reported = Mutex<JobResult?>(nil)
        let handedOff = Mutex<ArchiveHandOff?>(nil)
        let session: any GuestSession
        do {
            session = try sessions.launch(command) { [logger] line in
                if let result = GuestJobRunner.parseResult(line) {
                    reported.withLock { $0 = result }
                } else if let handOff = GuestJobRunner.parseHandOff(line) {
                    handedOff.withLock { $0 = handOff }
                } else {
                    logger.info("guest: \(line)", metadata: ["job": "\(jobID)"])
                }
            }
        } catch {
            return .hostFailure("could not start the job in its VM: \(error)")
        }
        let bundle = GuestJobBundle(
            assignment: assignment, token: token,
            serverURL: URL(string: "http://127.0.0.1:\(Self.guestServerPort)")!, identity: identity,
            vmNote: "VM: \(vm.note) on \(host.machineName)", machineName: "\(host.machineName) (VM)", signing: signing)
        guard let line = try? JSONCoding.encoder.encode(bundle) else { return .hostFailure("could not encode the job for its VM") }
        session.send(SensitiveText(String(decoding: line, as: UTF8.self)))

        let stopped = StopFlag()
        vm.machine.onStop { stop in
            stopped.set(stop)
            session.terminate()
        }
        let timeout = jobTimeout
        let minutes = Int(timeout.components.seconds / 60)
        let watch = Task { [clock = host.clock, grace = cancelGrace, machineName = host.machineName] () -> String? in
            let deadline = ContinuousClock.now + timeout
            var cancelSentAt: ContinuousClock.Instant?
            var reason: String?
            while !Task.isCancelled {
                if cancelSentAt == nil {
                    if cancelled() {
                        reason = stopReason()
                        session.send(SensitiveText(GuestControl.cancel(reason: reason).line))
                        cancelSentAt = .now
                    } else if ContinuousClock.now >= deadline {
                        reason = "the job ran longer than \(minutes) min, the VM job timeout on \(machineName)"
                        session.send(SensitiveText(GuestControl.cancel(reason: reason).line))
                        cancelSentAt = .now
                    }
                } else if let sent = cancelSentAt, ContinuousClock.now - sent >= grace {
                    session.terminate()
                    return reason ?? "cancelled"
                }
                try? await clock.sleep(for: .seconds(1))
            }
            return reason
        }
        let exitCode = await session.wait()
        watch.cancel()
        let watchReason = await watch.value
        if let result = reported.withLock({ $0 }) { return .reported(result) }
        // A hand-off the host cancelled meanwhile is not exported.
        if let handOff = handedOff.withLock({ $0 }) {
            if watchReason == nil, !cancelled() { return .handedOff(handOff) }
            return .cancelled(watchReason ?? stopReason())
        }
        if let stop = stopped.value {
            switch stop {
            case .guestStopped: return .hostFailure("the build VM shut down before the job finished")
            case .error(let detail): return .hostFailure("the build VM stopped: \(detail)")
            }
        }
        if let watchReason { return .cancelled(watchReason) }
        return .hostFailure(
            exitCode == 255
                ? "the build VM stopped responding (SSH dropped)"
                : "the job's process in the VM exited with status \(exitCode) without reporting a result")
    }

    // MARK: Reporting

    private func fail(_ jobID: UUID, _ reason: String) async -> JobResult {
        logger.error("\(reason)", metadata: ["job": "\(jobID)"])
        return await finish(jobID, JobResult(status: .failed, failureReason: reason))
    }

    /// The host's own finish, for what the guest could not report; a 409 means the guest (or the server) already did.
    private func finish(_ jobID: UUID, _ result: JobResult) async -> JobResult {
        await JobRunner.reportFinish(jobID: jobID, result, connection: connection, clock: host.clock, logger: logger)
        return result
    }
}

/// Which slots are free. Shared by the job runner and the slot preparation at start-up.
public final class VMSlotPool: Sendable {
    private let busy: Mutex<Set<Int>>
    public let count: Int

    public init(count: Int) {
        self.count = count
        busy = Mutex([])
    }

    /// The lowest free slot, now taken; nil when all are busy.
    public func acquire() -> Int? {
        busy.withLock { busy in
            guard let slot = (0..<count).first(where: { !busy.contains($0) }) else { return nil }
            busy.insert(slot)
            return slot
        }
    }

    /// Takes `slot` if it is free.
    public func acquire(_ slot: Int) -> Bool {
        busy.withLock { $0.insert(slot).inserted }
    }

    public func release(_ slot: Int) {
        _ = busy.withLock { $0.remove(slot) }
    }

    public var freeCount: Int { busy.withLock { count - $0.count } }
}
