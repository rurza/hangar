import Foundation

public struct InstalledXcode: Codable, Equatable, Sendable {
    public var version: String
    public var build: String
    public var path: String

    public init(version: String, build: String, path: String) {
        self.version = version
        self.build = build
        self.path = path
    }
}

/// What a worker build can do beyond the original protocol; the scheduler gives a job only to workers that have every
/// capability it needs.
public enum WorkerCapability {
    /// Runs test actions and decodes assignments that contain them.
    public static let testActions = "test-actions"
    /// Everything this build of the worker can do.
    public static let all = [testActions]
}

public struct MachineReport: Codable, Equatable, Sendable {
    public var macOSVersion: String
    public var xcodes: [InstalledXcode]
    public var chip: String
    public var performanceCores: Int
    public var memoryGB: Int
    public var freeDiskGB: Double
    public var onACPower: Bool
    public var tools: [String: String]
    public var canSignWithoutPrompt: Bool
    public var runningJobIDs: [UUID]
    /// The names of the valid code signing identities in the worker user's keychain (`security find-identity -v
    /// -p codesigning`), e.g. "Apple Distribution: Acme (TEAM123456)"; no hashes. Empty from an older worker.
    public var signingIdentities: [String]
    /// Whether Xcode on the worker has an Apple account signed in (Xcode › Settings › Accounts); nil when unknown,
    /// e.g. from an older worker.
    public var xcodeAccountSignedIn: Bool?
    /// Simulator runtimes with at least one available device, e.g. ["iOS 27.2", "visionOS 27.1"]. Empty when the
    /// worker reports none or predates the field.
    public var simulatorRuntimes: [String]
    /// `WorkerCapability` names; empty for a worker from before capabilities.
    public var capabilities: [String]
    /// SHA-256 of the running `hangar-worker`, computed when that process started. Nil from a worker that does not
    /// report it yet. The server offers a replacement when this differs from the binary it would hand out.
    public var binarySHA256: String?

    public init(
        macOSVersion: String, xcodes: [InstalledXcode], chip: String, performanceCores: Int,
        memoryGB: Int, freeDiskGB: Double, onACPower: Bool, tools: [String: String],
        canSignWithoutPrompt: Bool, runningJobIDs: [UUID], signingIdentities: [String] = [],
        xcodeAccountSignedIn: Bool? = nil, simulatorRuntimes: [String] = [], capabilities: [String] = [],
        binarySHA256: String? = nil
    ) {
        self.macOSVersion = macOSVersion
        self.xcodes = xcodes
        self.chip = chip
        self.performanceCores = performanceCores
        self.memoryGB = memoryGB
        self.freeDiskGB = freeDiskGB
        self.onACPower = onACPower
        self.tools = tools
        self.canSignWithoutPrompt = canSignWithoutPrompt
        self.runningJobIDs = runningJobIDs
        self.signingIdentities = signingIdentities
        self.xcodeAccountSignedIn = xcodeAccountSignedIn
        self.simulatorRuntimes = simulatorRuntimes
        self.capabilities = capabilities
        self.binarySHA256 = binarySHA256
    }

    private enum CodingKeys: String, CodingKey {
        case macOSVersion, xcodes, chip, performanceCores, memoryGB, freeDiskGB, onACPower, tools, canSignWithoutPrompt
        case runningJobIDs, signingIdentities, xcodeAccountSignedIn, simulatorRuntimes, capabilities, binarySHA256
    }

    /// An older worker sends none of the newer fields (`signingIdentities`, `xcodeAccountSignedIn`,
    /// `simulatorRuntimes`, `capabilities`): read as none and unknown.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macOSVersion = try container.decode(String.self, forKey: .macOSVersion)
        xcodes = try container.decode([InstalledXcode].self, forKey: .xcodes)
        chip = try container.decode(String.self, forKey: .chip)
        performanceCores = try container.decode(Int.self, forKey: .performanceCores)
        memoryGB = try container.decode(Int.self, forKey: .memoryGB)
        freeDiskGB = try container.decode(Double.self, forKey: .freeDiskGB)
        onACPower = try container.decode(Bool.self, forKey: .onACPower)
        tools = try container.decode([String: String].self, forKey: .tools)
        canSignWithoutPrompt = try container.decode(Bool.self, forKey: .canSignWithoutPrompt)
        runningJobIDs = try container.decode([UUID].self, forKey: .runningJobIDs)
        signingIdentities = try container.decodeIfPresent([String].self, forKey: .signingIdentities) ?? []
        xcodeAccountSignedIn = try container.decodeIfPresent(Bool.self, forKey: .xcodeAccountSignedIn)
        simulatorRuntimes = try container.decodeIfPresent([String].self, forKey: .simulatorRuntimes) ?? []
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        binarySHA256 = try container.decodeIfPresent(String.self, forKey: .binarySHA256)
    }
}

public struct Machine: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var maxConcurrentJobs: Int
    public var lastSeenAt: Date?
    public var report: MachineReport?
    public var createdAt: Date

    public init(
        id: UUID, name: String, maxConcurrentJobs: Int = 1, lastSeenAt: Date? = nil,
        report: MachineReport? = nil, createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.maxConcurrentJobs = maxConcurrentJobs
        self.lastSeenAt = lastSeenAt
        self.report = report
        self.createdAt = createdAt
    }

    public func isOnline(now: Date, timeout: TimeInterval = 90) -> Bool {
        guard let lastSeenAt else { return false }
        return now.timeIntervalSince(lastSeenAt) <= timeout
    }
}
