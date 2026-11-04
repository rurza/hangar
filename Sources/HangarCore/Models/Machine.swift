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

    public init(
        macOSVersion: String, xcodes: [InstalledXcode], chip: String, performanceCores: Int,
        memoryGB: Int, freeDiskGB: Double, onACPower: Bool, tools: [String: String],
        canSignWithoutPrompt: Bool, runningJobIDs: [UUID]
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
