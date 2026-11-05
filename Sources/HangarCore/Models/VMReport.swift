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

    public init(
        slots: Int, configuredSlots: Int, freeSlots: Int, storageFreeGB: Double, networkFilter: Bool,
        problem: String? = nil, images: [VMImageInfo] = []
    ) {
        self.slots = slots
        self.configuredSlots = configuredSlots
        self.freeSlots = freeSlots
        self.storageFreeGB = storageFreeGB
        self.networkFilter = networkFilter
        self.problem = problem
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case slots, configuredSlots, freeSlots, storageFreeGB, networkFilter, problem, images
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
