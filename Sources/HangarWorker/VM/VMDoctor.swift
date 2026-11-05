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

    public init(
        host: VMHost, identity: VMIdentityStore,
        networkFilterProblem: @escaping @Sendable () -> String? = { VMNetworkFilter.current().problem() }
    ) {
        self.host = host
        self.identity = identity
        self.networkFilterProblem = networkFilterProblem
    }

    public func report(runningJobs: Int) -> VMReport {
        let images = host.images().filter(\.metadata.isJobImage)
        let filterProblem = networkFilterProblem()
        let problem = self.problem(images: images, filterProblem: filterProblem)
        let slots = problem == nil ? host.settings.slots : 0
        return VMReport(
            slots: slots, configuredSlots: host.settings.slots, freeSlots: max(0, slots - runningJobs),
            storageFreeGB: (VMVolume.freeGB(at: host.storage.root) * 10).rounded() / 10, networkFilter: filterProblem == nil,
            problem: problem, images: images.map(\.metadata.info), ownIdentity: identity.exists)
    }

    /// What keeps VM jobs from running right now, or nil; checked before each job.
    public func readinessProblem() -> String? {
        problem(images: host.images().filter(\.metadata.isJobImage), filterProblem: networkFilterProblem())
    }

    /// The first thing that keeps VM jobs from running, or nil.
    public func problem(images: [VMImage], filterProblem: String?) -> String? {
        if let problem = host.settings.problem { return problem }
        if let reason = host.engine.unavailableReason() { return reason }
        if let problem = VMVolume.problem(at: host.storage.root) { return problem.description }
        if let filterProblem { return filterProblem }
        if images.isEmpty { return "no VM image with Xcode yet: build one with `hangar-worker vm image build`" }
        return nil
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
