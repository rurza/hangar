import Foundation
import HangarCore
import Synchronization

/// What every VM operation on this Mac needs.
public struct VMHost: Sendable {
    public var settings: VMSettings
    public var storage: VMStorage
    public var engine: any VirtualMachineEngine
    public var runner: any ProcessRunner
    /// This Mac's name: slot MAC addresses and failure reasons.
    public var machineName: String
    /// The host's macOS build ("25G83"); a saved state from another build may not restore.
    public var hostBuild: String
    public var leasesFile: String
    public var clock: any Clock<Duration>
    /// Whether a login session's screen is locked: saved states do not restore then (see `ConsoleLock`).
    public var screenIsLocked: @Sendable () -> Bool

    public init(
        settings: VMSettings, engine: any VirtualMachineEngine = LiveVirtualMachineEngine(),
        runner: any ProcessRunner = LiveProcessRunner(), machineName: String = JobRunner.computerName,
        hostBuild: String = VMHost.currentHostBuild(), leasesFile: String = DHCPLeases.path,
        clock: any Clock<Duration> = ContinuousClock(), screenIsLocked: @escaping @Sendable () -> Bool = ConsoleLock.screenIsLocked
    ) {
        self.settings = settings
        self.storage = VMStorage(root: settings.storage)
        self.engine = engine
        self.runner = runner
        self.machineName = machineName
        self.hostBuild = hostBuild
        self.leasesFile = leasesFile
        self.clock = clock
        self.screenIsLocked = screenIsLocked
    }

    public static func currentHostBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// SSH into clones of `image`, its host keys pinned.
    public func ssh(for image: VMImageDirectory) -> GuestSSH {
        GuestSSH(runner: runner, privateKey: storage.privateKey, hostKeys: .pinned(knownHosts: image.knownHosts))
    }

    /// The complete images with their metadata and Tart configuration; unreadable ones are skipped.
    public func images() -> [VMImage] {
        storage.imageNames().compactMap { name in try? VMImage(directory: storage.image(name)) }
    }

    /// The job image whose Xcode matches `requested` best: the highest matching version.
    public func image(forXcode requested: String) -> VMImage? {
        let candidates = images().filter { $0.metadata.isJobImage }
        let xcodes = candidates.compactMap { image in
            image.metadata.xcode.map { InstalledXcode(version: $0, build: image.metadata.xcodeBuild ?? "", path: image.directory.path) }
        }
        guard let best = XcodeVersion.best(xcodes, requested: requested) else { return nil }
        return candidates.first { $0.directory.path == best.path }
    }
}

/// An image as it is on disk.
public struct VMImage: Sendable, Equatable {
    public var directory: VMImageDirectory
    public var metadata: VMImageMetadata
    public var config: TartConfig

    public init(directory: VMImageDirectory) throws {
        self.directory = directory
        metadata = try VMBundleFile.read(VMImageMetadata.self, at: directory.metadata)
        config = try VMBundleFile.read(TartConfig.self, at: directory.config)
    }

    public func hardwareModel() throws -> Data {
        guard let data = config.hardwareModelData else { throw VMError.invalidConfiguration("config.json has no hardware model") }
        return data
    }
}

/// A VM that is up, with SSH answering.
public struct RunningVM: Sendable {
    public var machine: any VirtualMachine
    public var address: String
    /// "restored slot 0's saved state in 4.5 s" or "cold-booted in 18.2 s (no saved state)".
    public var note: String
    /// The slot's state did not fit and should be saved again once the slot is free.
    public var slotIsStale: Bool
}

/// Boots VMs from images and slots (VM builds design, *Saved states, one per slot* and *Per-job lifecycle*).
public struct VMLauncher: Sendable {
    public var host: VMHost
    /// How long a restored guest may take to answer SSH, and a cold-booted one.
    public var restoreDeadline: Duration = .seconds(90)
    public var bootDeadline: Duration = .seconds(300)
    /// Polling interval for the DHCP lease and SSH.
    public var pollInterval: Duration = .milliseconds(250)

    public init(host: VMHost) { self.host = host }

    // MARK: A job's VM

    /// Clones slot `slot` of `image` into `job` and restores its saved state; cold-boots a clone of the image itself
    /// when the slot has no usable state. The caller stops the VM and deletes `job` whatever happens.
    public func bootJob(image: VMImage, slot: Int, job: VMJobDirectory, user: String) async throws -> RunningVM {
        try FileManager.default.createDirectory(atPath: job.share, withIntermediateDirectories: true)
        try WorkerPrivacy.setMode(0o700, at: job.path)
        let slotDirectory = image.directory.slot(slot)
        let metadata = try? VMBundleFile.read(VMSlotMetadata.self, at: slotDirectory.metadata)
        var staleness: String?
        if let metadata, FileManager.default.fileExists(atPath: slotDirectory.state) {
            staleness = metadata.staleness(settings: host.settings, image: image.metadata, hostBuild: host.hostBuild)
        } else {
            staleness = "no saved state"
        }
        let started = ContinuousClock.now
        if staleness == nil, let metadata {
            try VMVolume.clone(slotDirectory.disk, to: job.disk)
            try VMVolume.clone(slotDirectory.nvram, to: job.nvram)
            let machine = try host.engine.make(try spec(image, metadata: metadata, disk: job.disk, nvram: job.nvram, share: job.share))
            do {
                try await machine.restore(from: slotDirectory.state)
                let address = try await waitForSSH(machine, mac: metadata.macAddress, user: user, image: image, deadline: restoreDeadline)
                return RunningVM(
                    machine: machine, address: address,
                    note: "restored slot \(slot)'s saved state in \(Self.seconds(since: started))", slotIsStale: false)
            } catch {
                // Stopped on every path: the clone is deleted under it, and it would count against the two VMs.
                await machine.stop()
                if error is CancellationError { throw error }
                if case VMError.tooManyVMs = error { throw error }
                // The Secure Enclave will not decrypt a state while a screen is locked; it restores again once the
                // Mac is unlocked. Saving it again would not help (the new one is as unreadable until then), so it
                // stays, and the slot is not saved again after the job.
                if case VMError.stateUnreadable(let detail) = error, host.screenIsLocked() {
                    for file in [job.disk, job.nvram] { try? FileManager.default.removeItem(atPath: file) }
                    return try await coldBoot(
                        image: image, slot: slot, job: job, user: user, metadata: metadata,
                        reason: "the saved state cannot be read while this Mac's screen is locked, and restores again once it is unlocked: \(detail)",
                        slotIsStale: false)
                }
                // A state that does not restore, or a guest that does not come back from it, would fail every job
                // of the slot the same way: it goes, and this job cold-boots.
                switch error {
                case VMError.stateIncompatible(let detail), VMError.stateUnreadable(let detail):
                    staleness = "the saved state did not restore: \(detail)"
                default:
                    staleness = "the restored VM did not come up: \(error)"
                }
                try? FileManager.default.removeItem(atPath: slotDirectory.state)
                for file in [job.disk, job.nvram] { try? FileManager.default.removeItem(atPath: file) }
            }
        }
        return try await coldBoot(
            image: image, slot: slot, job: job, user: user, metadata: metadata, reason: staleness ?? "no saved state",
            slotIsStale: true)
    }

    /// Cold-boots a clone of the image itself into `job`, as slot `slot` when it has an identity.
    private func coldBoot(
        image: VMImage, slot: Int, job: VMJobDirectory, user: String, metadata: VMSlotMetadata?, reason: String,
        slotIsStale: Bool
    ) async throws -> RunningVM {
        // The slot's identity when it has one, with today's CPUs and memory: a cold boot has no state to match.
        var identity = metadata ?? newSlotIdentity(slot: slot, imageID: image.metadata.id)
        identity.cpus = host.settings.cpus
        identity.memoryGB = host.settings.memoryGB
        try VMVolume.clone(image.directory.disk, to: job.disk)
        try VMVolume.clone(image.directory.nvram, to: job.nvram)
        let machine = try host.engine.make(try spec(image, metadata: identity, disk: job.disk, nvram: job.nvram, share: job.share))
        let coldStart = ContinuousClock.now
        try await machine.start()
        do {
            let address = try await waitForSSH(machine, mac: identity.macAddress, user: user, image: image, deadline: bootDeadline)
            return RunningVM(
                machine: machine, address: address,
                note: "cold-booted in \(Self.seconds(since: coldStart)) (\(reason))", slotIsStale: slotIsStale)
        } catch {
            await machine.stop()
            throw error
        }
    }

    // MARK: A slot's saved state

    /// Makes slot `slot`'s saved state: clones the image, gives the slot its own machine identifier and MAC, cold-boots,
    /// waits for the build user's session and for the guest to settle, then pauses and saves. Replaces what was there.
    public func prepareSlot(image: VMImage, slot: Int, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let directory = image.directory.slot(slot)
        try? FileManager.default.removeItem(atPath: directory.path)
        try FileManager.default.createDirectory(atPath: directory.share, withIntermediateDirectories: true)
        let identity = newSlotIdentity(slot: slot, imageID: image.metadata.id)
        try VMVolume.clone(image.directory.disk, to: directory.disk)
        try VMVolume.clone(image.directory.nvram, to: directory.nvram)
        let machine = try host.engine.make(
            try spec(image, metadata: identity, disk: directory.disk, nvram: directory.nvram, share: directory.share))
        let started = ContinuousClock.now
        progress("slot \(slot): booting \(image.metadata.name)")
        try await machine.start()
        do {
            let user = image.metadata.buildUser ?? "admin"
            let address = try await waitForSSH(machine, mac: identity.macAddress, user: user, image: image, deadline: bootDeadline)
            progress("slot \(slot): up at \(address) after \(Self.seconds(since: started)); waiting for it to settle")
            try await settle(address: address, user: user, image: image, progress: progress)
            let saving = ContinuousClock.now
            try await machine.save(to: directory.state)
            progress("slot \(slot): saved its state in \(Self.seconds(since: saving))")
        } catch {
            await machine.stop()
            try? FileManager.default.removeItem(atPath: directory.path)
            throw error
        }
        await machine.stop()
        try VMBundleFile.write(identity, to: directory.metadata)
    }

    /// Waits until `user` has the console (automatic login) and the load average stays under 1 for 30 s, which is
    /// why images turn Spotlight off: a freshly booted guest sits at a load of 50. Gives up waiting after 5 minutes
    /// and saves anyway.
    func settle(address: String, user: String, image: VMImage, progress: @escaping @Sendable (String) -> Void) async throws {
        let ssh = host.ssh(for: image.directory)
        // One sample every 5 s: six quiet ones in a row are 30 s, sixty samples are 5 minutes.
        var quiet = 0
        for _ in 0..<60 {
            let outcome = try await ssh.run(user: user, host: address, "stat -f %Su /dev/console; sysctl -n vm.loadavg")
            let lines = outcome.output.split(separator: "\n").map(String.init)
            let consoleUser = lines.first ?? ""
            let load = lines.dropFirst().first.flatMap { Self.oneMinuteLoad($0) } ?? 99
            if outcome.exitCode == 0, consoleUser == user || image.metadata.buildUser == nil, load < 1 {
                quiet += 1
                if quiet >= 6 { return }
            } else {
                quiet = 0
            }
            try await host.clock.sleep(for: .seconds(5))
        }
        progress("the guest did not settle within 5 minutes; saving anyway")
    }

    /// "{ 0.52 0.61 0.80 }" → 0.52.
    static func oneMinuteLoad(_ text: String) -> Double? {
        text.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "}" }).first.flatMap { Double($0) }
    }

    // MARK: Plumbing

    func newSlotIdentity(slot: Int, imageID: UUID = UUID()) -> VMSlotMetadata {
        VMSlotMetadata(
            macAddress: VMMACAddress.forSlot(slot, machine: host.machineName),
            machineIdentifier: host.engine.newMachineIdentifier().base64EncodedString(),
            cpus: host.settings.cpus, memoryGB: host.settings.memoryGB, imageID: imageID, hostBuild: host.hostBuild,
            savedAt: Date())
    }

    func spec(_ image: VMImage, metadata: VMSlotMetadata, disk: String, nvram: String, share: String) throws -> VMSpec {
        guard let machineIdentifier = Data(base64Encoded: metadata.machineIdentifier) else {
            throw VMError.invalidConfiguration("slot.json has no machine identifier")
        }
        return VMSpec(
            hardwareModel: try image.hardwareModel(), machineIdentifier: machineIdentifier, disk: disk, nvram: nvram,
            cpus: metadata.cpus, memoryBytes: UInt64(metadata.memoryGB) * 1024 * 1024 * 1024,
            macAddress: metadata.macAddress, share: share)
    }

    /// Waits for the guest's DHCP lease, then for `ssh user@address true`. Fails early when the VM stops.
    func waitForSSH(
        _ machine: any VirtualMachine, mac: String, user: String, image: VMImage, deadline: Duration
    ) async throws -> String {
        let stopped = StopFlag()
        machine.onStop { stopped.set($0) }
        let end = ContinuousClock.now + deadline
        let ssh = host.ssh(for: image.directory)
        while ContinuousClock.now < end {
            if let stop = stopped.value { throw VMError.failed("the VM stopped while booting: \(stop)") }
            if let address = DHCPLeases.address(for: mac, leasesFile: host.leasesFile) {
                var probe = ssh.command(user: user, host: address, "true")
                probe.arguments = probe.arguments.map { $0 == "ConnectTimeout=5" ? "ConnectTimeout=2" : $0 }
                if try await host.runner.run(probe, onLine: { _ in }).exitCode == 0 { return address }
            }
            try await host.clock.sleep(for: pollInterval)
        }
        throw VMError.failed("the VM did not answer SSH within \(deadline)")
    }

    static func seconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return String(format: "%.1f s", seconds)
    }
}

/// How a VM stopped, set from Virtualization.framework's queue.
final class StopFlag: Sendable {
    private let state = Mutex<VMStop?>(nil)
    var value: VMStop? { state.withLock { $0 } }
    func set(_ stop: VMStop) { state.withLock { $0 = $0 ?? stop } }
}
