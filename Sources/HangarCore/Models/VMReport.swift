import Foundation

/// One prepared VM image on a machine (VM builds design, *Image storage*): what a job in it gets.
public struct VMImageInfo: Codable, Equatable, Sendable {
    /// The image's directory name, e.g. "xcode-27.2".
    public var name: String
    /// The guest's macOS, e.g. "26.6.2 (25G83)".
    public var macOS: String
    /// The Xcode version in the image, e.g. "27.2"; nil for an image without Xcode (a vanilla import).
    public var xcode: String?
    public var xcodeBuild: String?
    /// Simulator runtimes in the image, e.g. ["iOS 27.2"].
    public var simulatorRuntimes: [String]

    public init(name: String, macOS: String, xcode: String? = nil, xcodeBuild: String? = nil, simulatorRuntimes: [String] = []) {
        self.name = name
        self.macOS = macOS
        self.xcode = xcode
        self.xcodeBuild = xcodeBuild
        self.simulatorRuntimes = simulatorRuntimes
    }

    private enum CodingKeys: String, CodingKey { case name, macOS, xcode, xcodeBuild, simulatorRuntimes }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        macOS = try container.decodeIfPresent(String.self, forKey: .macOS) ?? ""
        xcode = try container.decodeIfPresent(String.self, forKey: .xcode)
        xcodeBuild = try container.decodeIfPresent(String.self, forKey: .xcodeBuild)
        simulatorRuntimes = try container.decodeIfPresent([String].self, forKey: .simulatorRuntimes) ?? []
    }
}

/// One row of a VM Mac's readiness checklist (`VMReport.checks`): what VM builds need, whether this Mac has it, and
/// the command that fixes it, as an administrator types it on that Mac.
public struct VMCheck: Codable, Equatable, Sendable {
    /// What is checked: "settings", "entitlement", "storage", "networkFilter", "image" or "slotStates". A string, so
    /// an older server shows a newer worker's rows.
    public var id: String
    /// "Network filter".
    public var title: String
    public var ok: Bool
    /// False for a row jobs run without (saved slot states: a job cold-boots instead).
    public var required: Bool
    /// What was found: "loaded", or what is wrong.
    public var detail: String
    /// The command to run on the Mac when `ok` is false, or nil when there is none to give.
    public var command: String?

    public init(id: String, title: String, ok: Bool, required: Bool = true, detail: String, command: String? = nil) {
        self.id = id
        self.title = title
        self.ok = ok
        self.required = required
        self.detail = detail
        self.command = command
    }
}

/// The VM side of a machine (`MachineReport.vm`). Present only when the worker is configured for VM builds; such a
/// machine runs every job in a VM and none on the host. With `slots` at 0 it takes no jobs, and `problem` says why.
public struct VMReport: Codable, Equatable, Sendable {
    /// VM slots ready to take a job: 0 while something is missing (the network filter, an image).
    public var slots: Int
    /// Slots the worker is configured for (`vm.slots`), ready or not.
    public var configuredSlots: Int
    /// Ready slots without a job.
    public var freeSlots: Int
    /// Free space on the VM storage volume.
    public var storageFreeGB: Double
    /// The pf anchor that keeps guests off the host and the LAN is loaded (VM builds design, *Network*).
    public var networkFilter: Bool
    /// Why no slot is ready, in plain English ("the network filter is not installed: run …"); nil when slots > 0.
    public var problem: String?
    public var images: [VMImageInfo]
    /// The worker holds its own identity (`hangar-worker vm identity import`), which overrides the server's: its VM
    /// archives do not need the server's.
    public var ownIdentity: Bool
    /// Everything VM builds need, in order, each with its state; empty from an older worker, which sends `problem`
    /// only.
    public var checks: [VMCheck]
    /// `sudo <worker> vm setup` as typed on this Mac: it also builds a job image for a new Xcode, so the Machines
    /// page shows it when the host's Xcode has no image yet.
    public var setupCommand: String?

    public init(
        slots: Int, configuredSlots: Int, freeSlots: Int, storageFreeGB: Double, networkFilter: Bool,
        problem: String? = nil, images: [VMImageInfo] = [], ownIdentity: Bool = false, checks: [VMCheck] = [],
        setupCommand: String? = nil
    ) {
        self.ownIdentity = ownIdentity
        self.checks = checks
        self.setupCommand = setupCommand
        self.slots = slots
        self.configuredSlots = configuredSlots
        self.freeSlots = freeSlots
        self.storageFreeGB = storageFreeGB
        self.networkFilter = networkFilter
        self.problem = problem
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case slots, configuredSlots, freeSlots, storageFreeGB, networkFilter, problem, images, ownIdentity, checks
        case setupCommand
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slots = try container.decode(Int.self, forKey: .slots)
        configuredSlots = try container.decodeIfPresent(Int.self, forKey: .configuredSlots) ?? slots
        freeSlots = try container.decodeIfPresent(Int.self, forKey: .freeSlots) ?? slots
        storageFreeGB = try container.decodeIfPresent(Double.self, forKey: .storageFreeGB) ?? 0
        networkFilter = try container.decodeIfPresent(Bool.self, forKey: .networkFilter) ?? false
        problem = try container.decodeIfPresent(String.self, forKey: .problem)
        images = try container.decodeIfPresent([VMImageInfo].self, forKey: .images) ?? []
        ownIdentity = try container.decodeIfPresent(Bool.self, forKey: .ownIdentity) ?? false
        checks = try container.decodeIfPresent([VMCheck].self, forKey: .checks) ?? []
        setupCommand = try container.decodeIfPresent(String.self, forKey: .setupCommand)
    }

    /// The Xcode versions a job can get on this machine: those of its images.
    public var xcodeVersions: [String] { images.compactMap(\.xcode) }
}

/// `POST /api/v1/worker/jobs/{id}/token`: a bearer token that works only for that job's own worker routes (start,
/// info, steps, log, artifacts, finish) and only while the job is assigned or running. The host worker hands it to
/// the job's VM instead of its machine token.
public struct JobTokenResponse: Codable, Equatable, Sendable {
    public var token: String

    public init(token: String) { self.token = token }
}
