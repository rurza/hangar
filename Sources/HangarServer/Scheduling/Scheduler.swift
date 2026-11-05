import Foundation
import HangarCore

/// A queued job as the scheduler sees it.
public struct QueuedJob: Sendable {
    public var id: UUID
    public var buildID: UUID
    public var createdAt: Date
    public var xcode: String
    public var tools: [String]
    public var pinnedMachineID: UUID?
    /// Set for a test on a simulator platform: the machine needs a runtime of it.
    public var simulatorPlatform: Platform?
    /// `WorkerCapability` names the worker must report.
    public var requiredCapabilities: Set<String>
    /// An archive whose App Store Connect key has no issuer ID: xcodebuild then signs with the Xcode account on the
    /// machine, which a headless worker does not have.
    public var needsXcodeAccount: Bool

    public init(
        id: UUID, buildID: UUID, createdAt: Date, xcode: String, tools: [String], pinnedMachineID: UUID?,
        simulatorPlatform: Platform? = nil, requiredCapabilities: Set<String> = [], needsXcodeAccount: Bool = false
    ) {
        self.simulatorPlatform = simulatorPlatform
        self.requiredCapabilities = requiredCapabilities
        self.needsXcodeAccount = needsXcodeAccount
        self.id = id
        self.buildID = buildID
        self.createdAt = createdAt
        self.xcode = xcode
        self.tools = tools
        self.pinnedMachineID = pinnedMachineID
    }
}

/// A machine as the scheduler sees it at the start of a tick.
public struct MachineSnapshot: Sendable {
    public var id: UUID
    public var name: String
    public var isOnline: Bool
    public var freeSlots: Int
    public var runningJobs: Int
    public var xcodeVersions: [String]
    public var tools: Set<String>
    public var freeDiskGB: Double
    public var performanceCores: Int
    public var onACPower: Bool
    public var canSign: Bool
    /// "iOS 27.2"…, as the machine reports them.
    public var simulatorRuntimes: [String]
    public var capabilities: Set<String>
    /// The worker runs without a login session (`MachineReport.headless`), so it has no Xcode account.
    public var headless: Bool
    /// Builds are turned off on this Mac (`Machine.paused`).
    public var paused: Bool
    /// Every job on this Mac runs in a VM (`MachineReport.vm`): `freeSlots` counts its ready VM slots,
    /// `xcodeVersions` and `simulatorRuntimes` are its images', `freeDiskGB` is its VM storage's, and `tools` are not
    /// required (a `ci_post_clone.sh` installs what it needs).
    public var vm: Bool
    /// Why none of the Mac's VM slots is ready; set only for a VM machine that reports no ready slot.
    public var vmNotReady: String?

    public init(
        id: UUID, name: String, isOnline: Bool, freeSlots: Int, runningJobs: Int, xcodeVersions: [String],
        tools: Set<String>, freeDiskGB: Double, performanceCores: Int, onACPower: Bool, canSign: Bool,
        simulatorRuntimes: [String] = [], capabilities: Set<String> = [], headless: Bool = false, paused: Bool = false,
        vm: Bool = false, vmNotReady: String? = nil
    ) {
        self.vm = vm
        self.vmNotReady = vmNotReady
        self.paused = paused
        self.simulatorRuntimes = simulatorRuntimes
        self.capabilities = capabilities
        self.headless = headless
        self.id = id
        self.name = name
        self.isOnline = isOnline
        self.freeSlots = freeSlots
        self.runningJobs = runningJobs
        self.xcodeVersions = xcodeVersions
        self.tools = tools
        self.freeDiskGB = freeDiskGB
        self.performanceCores = performanceCores
        self.onACPower = onACPower
        self.canSign = canSign
    }
}

/// Why a machine cannot take a job; `description` is UI/CLI copy.
public enum Ineligibility: Equatable, Sendable, CustomStringConvertible {
    case offline
    case busy
    case xcodeMissing(String)
    case lowDisk(freeGB: Double, minimumGB: Double)
    case toolMissing(String)
    case cannotSign
    case notPinned
    /// No simulator runtime of this platform ("iOS").
    case simulatorMissing(String)
    /// The worker lacks a capability the job needs: it predates the feature.
    case workerOutdated
    /// An archive with an individual App Store Connect key, on a headless worker: there is no Xcode account to sign with.
    case needsTeamKey
    /// Its owner turned builds off on this Mac. Like busy, it passes: the job waits until the machine is resumed.
    case paused
    /// A VM machine with no VM slot ready, and why (the network filter is missing, no image yet…).
    case vmNotReady(String)
    /// A VM machine without an image of this Xcode version.
    case noVMImage(String)

    public var description: String {
        switch self {
        case .offline: "offline"
        case .busy: "busy"
        case .paused: "builds paused"
        case .vmNotReady(let problem): "VM builds not ready: \(problem)"
        case .noVMImage(let version): "no VM image with Xcode \(version)"
        case .xcodeMissing(let version): "Xcode \(version) not installed"
        case .lowDisk(let free, let minimum): "only \(Self.gigabytes(free)) GB free (needs \(Self.gigabytes(minimum)) GB)"
        case .toolMissing(let tool): "\(tool) not installed"
        case .cannotSign: "cannot sign without a prompt"
        case .notPinned: "job is pinned to another machine"
        case .simulatorMissing(let platform): "no \(platform) simulator"
        case .workerOutdated: "update the worker (run the install command again)"
        case .needsTeamKey:
            "needs a team App Store Connect key (with an issuer ID): this Mac's worker runs without an Xcode account"
        }
    }

    /// "12" for 12.0, "12.5" for 12.5.
    private static func gigabytes(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

public struct Assignment: Equatable, Sendable {
    public var jobID: UUID
    public var machineID: UUID

    public init(jobID: UUID, machineID: UUID) {
        self.jobID = jobID
        self.machineID = machineID
    }
}

public struct SchedulerPlan: Equatable, Sendable {
    public var assignments: [Assignment]
    /// Job ID → machine name → why that machine cannot take it.
    public var waiting: [UUID: [String: [Ineligibility]]]

    public init(assignments: [Assignment], waiting: [UUID: [String: [Ineligibility]]]) {
        self.assignments = assignments
        self.waiting = waiting
    }
}

public enum Scheduler {
    /// Jobs FIFO by `createdAt`; each goes to the best eligible machine, ranked idle first, then by
    /// performance cores, free disk and AC power. A chosen machine loses a slot before the next job.
    public static func plan(jobs: [QueuedJob], machines: [MachineSnapshot], minFreeDiskGB: Double) -> SchedulerPlan {
        var machines = machines
        var plan = SchedulerPlan(assignments: [], waiting: [:])
        let ordered = jobs.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        for job in ordered {
            var reasons: [String: [Ineligibility]] = [:]
            var eligible: [Int] = []
            for (index, machine) in machines.enumerated() {
                let blockers = ineligibility(of: job, on: machine, minFreeDiskGB: minFreeDiskGB)
                if blockers.isEmpty { eligible.append(index) } else { reasons[machine.name] = blockers }
            }
            guard let best = eligible.min(by: { rank(machines[$0]) < rank(machines[$1]) }) else {
                plan.waiting[job.id] = reasons
                continue
            }
            plan.assignments.append(Assignment(jobID: job.id, machineID: machines[best].id))
            machines[best].freeSlots -= 1
            machines[best].runningJobs += 1
        }
        return plan
    }

    /// `"<machine>: <reason>, <reason>; <machine>: <reason>"`, machines sorted by name.
    public static func queueNote(_ reasons: [String: [Ineligibility]]) -> String {
        guard !reasons.isEmpty else { return "no machines registered" }
        return reasons.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.map(\.description).joined(separator: ", "))" }
            .joined(separator: "; ")
    }

    /// Empty when the machine can take the job. An offline machine reports only that, since its data is stale.
    static func ineligibility(of job: QueuedJob, on machine: MachineSnapshot, minFreeDiskGB: Double) -> [Ineligibility] {
        if let pinned = job.pinnedMachineID, pinned != machine.id { return [.notPinned] }
        guard machine.isOnline else { return [.offline] }
        // An outdated worker could not even read the assignment; its other data says nothing about this job.
        guard job.requiredCapabilities.isSubset(of: machine.capabilities) else { return [.workerOutdated] }
        var reasons: [Ineligibility] = []
        // First, so a queue note reads "mini: builds paused, Xcode 27.2 not installed".
        if machine.paused { reasons.append(.paused) }
        // A VM machine with no ready slot says why, not that it is busy.
        if let problem = machine.vmNotReady { reasons.append(.vmNotReady(problem)) }
        else if machine.freeSlots <= 0 { reasons.append(.busy) }
        if !machine.xcodeVersions.contains(where: { XcodeVersion.matches(requested: job.xcode, installed: $0) }) {
            reasons.append(machine.vm ? .noVMImage(job.xcode) : .xcodeMissing(job.xcode))
        }
        if machine.freeDiskGB < minFreeDiskGB {
            reasons.append(.lowDisk(freeGB: machine.freeDiskGB, minimumGB: minFreeDiskGB))
        }
        // In a VM, the job installs its own tools, as on Xcode Cloud.
        if !machine.vm { reasons += job.tools.filter { !machine.tools.contains($0) }.map(Ineligibility.toolMissing) }
        if !machine.canSign { reasons.append(.cannotSign) }
        if job.needsXcodeAccount, machine.headless { reasons.append(.needsTeamKey) }
        if let platform = job.simulatorPlatform,
            !machine.simulatorRuntimes.contains(where: { $0.hasPrefix(platform.ciName + " ") })
        {
            reasons.append(.simulatorMissing(platform.ciName))
        }
        return reasons
    }

    /// Lower is better; the name breaks ties so plans are deterministic.
    private static func rank(_ machine: MachineSnapshot) -> (Int, Int, Double, Int, String) {
        (machine.runningJobs == 0 ? 0 : 1, -machine.performanceCores, -machine.freeDiskGB,
         machine.onACPower ? 0 : 1, machine.name)
    }
}
