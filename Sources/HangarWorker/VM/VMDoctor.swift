import Foundation
import HangarCore

/// The `vm` section of the machine report (VM builds design, *Scheduler and reporting*): slots are reported ready only
/// when everything a VM job needs is in place, the network filter first. A Mac with VM builds turned on but not ready
/// takes no jobs, rather than building on the host next to its owner's tools.
public struct VMDoctor: Sendable {
    public var host: VMHost
    /// This worker's own identity, if any: it overrides the server's, which comes with each archive's assignment.
    public var identity: VMIdentityStore
    /// Reads the network filter's state; the marker check by default.
    public var networkFilterProblem: @Sendable () -> String?
    /// How the commands in the report are typed on this Mac.
    public var commands: WorkerCommandLine

    public init(
        host: VMHost, identity: VMIdentityStore,
        networkFilterProblem: (@Sendable () -> String?)? = nil,
        commands: WorkerCommandLine = .current()
    ) {
        self.host = host
        self.identity = identity
        self.commands = commands
        self.networkFilterProblem = networkFilterProblem ?? {
            VMNetworkFilter.current().problem(installCommand: commands.asRoot("vm", "network", "install"))
        }
    }

    public func report(runningJobs: Int) -> VMReport {
        let images = host.images().filter(\.metadata.isJobImage)
        let filterProblem = networkFilterProblem()
        let checks = self.checks(images: images, filterProblem: filterProblem)
        let problem = Self.firstProblem(checks)
        let slots = problem == nil ? host.settings.slots : 0
        return VMReport(
            slots: slots, configuredSlots: host.settings.slots, freeSlots: max(0, slots - runningJobs),
            storageFreeGB: (VMVolume.freeGB(at: host.storage.root) * 10).rounded() / 10, networkFilter: filterProblem == nil,
            problem: problem, images: images.map(\.metadata.info), ownIdentity: identity.exists, checks: checks,
            imageBuildCommand: commands.asWorker("vm", "image", "build"))
    }

    /// What keeps VM jobs from running right now, or nil; checked before each job.
    public func readinessProblem() -> String? {
        problem(images: host.images().filter(\.metadata.isJobImage), filterProblem: networkFilterProblem())
    }

    /// The first thing that keeps VM jobs from running, or nil.
    public func problem(images: [VMImage], filterProblem: String?) -> String? {
        Self.firstProblem(checks(images: images, filterProblem: filterProblem))
    }

    /// The first required row that fails, with its command: "no VM image with Xcode yet: run `sudo … vm setup`".
    static func firstProblem(_ checks: [VMCheck]) -> String? {
        checks.first { $0.required && !$0.ok }.map { check in
            check.command.map { "\(check.detail): run `\($0)`" } ?? check.detail
        }
    }

    /// Everything VM jobs need, in the order to fix it, each with its state. A later row is checked even when an
    /// earlier one fails, so the Machines page shows the whole list at once.
    public func checks(images: [VMImage], filterProblem: String?) -> [VMCheck] {
        let settings = host.settings
        var checks: [VMCheck] = []
        let settingsProblem = settings.problem
        checks.append(VMCheck(
            id: "settings", title: "VM settings", ok: settingsProblem == nil,
            detail: settingsProblem
                ?? "\(settings.slots) \(settings.slots == 1 ? "slot" : "slots") of \(settings.cpus) CPUs and \(settings.memoryGB) GB",
            command: settingsProblem == nil ? nil : commands.asWorker("vm", "enable")))
        let engineProblem = host.engine.unavailableReason()
        checks.append(VMCheck(
            id: "entitlement", title: "Virtualization", ok: engineProblem == nil,
            detail: engineProblem ?? "this Mac and its worker can run macOS VMs"))
        let storageProblem = VMVolume.problem(at: host.storage.root)
        let free = (VMVolume.freeGB(at: host.storage.root) * 10).rounded() / 10
        checks.append(VMCheck(
            id: "storage", title: "Storage", ok: storageProblem == nil,
            detail: storageProblem?.description ?? "\(host.storage.root), \(free) GB free",
            command: storageProblem == nil ? nil : commands.vmSetup))
        checks.append(VMCheck(
            id: "networkFilter", title: "Network filter", ok: filterProblem == nil,
            // The filter's own message names the command.
            detail: filterProblem ?? "loaded: VMs cannot reach this Mac, the LAN or the tailnet"))
        let versions = images.compactMap(\.metadata.xcode)
        checks.append(VMCheck(
            id: "image", title: "Xcode image", ok: !images.isEmpty,
            detail: images.isEmpty
                ? "no VM image with Xcode yet"
                : "Xcode \(versions.isEmpty ? "?" : versions.joined(separator: ", "))",
            command: images.isEmpty ? commands.vmSetup : nil))
        if !images.isEmpty {
            let unsaved = images.flatMap { image in
                (0..<settings.slots).compactMap { slot -> String? in
                    let state = Self.slotState(image: image, slot: slot, host: host)
                    return state.hasPrefix("saved") ? nil : "\(image.metadata.name) slot \(slot)"
                }
            }
            checks.append(VMCheck(
                id: "slotStates", title: "Saved states", ok: unsaved.isEmpty, required: false,
                detail: unsaved.isEmpty
                    ? "every slot restores in seconds"
                    : "\(unsaved.joined(separator: ", ")): no current saved state, so a job there cold-boots (about 20 s more) and saves one"))
        }
        return checks
    }

    /// One line per slot for `vm image list`.
    public static func slotState(image: VMImage, slot: Int, host: VMHost) -> String {
        let directory = image.directory.slot(slot)
        guard let metadata = try? VMBundleFile.read(VMSlotMetadata.self, at: directory.metadata),
            FileManager.default.fileExists(atPath: directory.state)
        else { return "no saved state (jobs cold-boot until `vm slots prepare`)" }
        if let stale = metadata.staleness(settings: host.settings, image: image.metadata, hostBuild: host.hostBuild) {
            return "stale: \(stale) (the next job cold-boots and saves it again)"
        }
        let formatter = ISO8601DateFormatter()
        return "saved \(formatter.string(from: metadata.savedAt)), \(metadata.cpus) CPUs, \(metadata.memoryGB) GB, MAC \(metadata.macAddress)"
    }
}

/// Start-up work for VM builds: leftovers swept, the host's key made, missing or stale slot states saved again.
public enum VMMaintenance {
    /// Deletes every job clone (no VM survives its process) and what an interrupted installer left. Returns lines to log.
    public static func sweep(storage: VMStorage) -> [String] {
        try? storage.create()
        var lines = storage.sweepJobs().map { "swept leftover VM clone \($0)" }
        lines += VMStorage.sweepInstallerLeftovers().map { "swept leftover macOS installer files \($0)" }
        return lines
    }

    /// Saves the state of every slot of every job image that has none or a stale one, each while holding the slot
    /// so no job uses it meanwhile. A slot a job holds is skipped: that job saves it when it ends.
    public static func prepareSlots(
        host: VMHost, pool: VMSlotPool, log: @escaping @Sendable (String) -> Void
    ) async {
        let launcher = VMLauncher(host: host)
        for image in host.images().filter(\.metadata.isJobImage) {
            for slot in 0..<pool.count {
                let state = VMDoctor.slotState(image: image, slot: slot, host: host)
                guard state.hasPrefix("no saved state") || state.hasPrefix("stale"), pool.acquire(slot) else { continue }
                log("saving \(image.metadata.name) slot \(slot)'s state (\(state))")
                do {
                    try await launcher.prepareSlot(image: image, slot: slot, progress: log)
                } catch {
                    log("could not save \(image.metadata.name) slot \(slot)'s state: \(error); its jobs cold-boot")
                }
                pool.release(slot)
            }
        }
    }
}
