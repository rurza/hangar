import Foundation

/// The `vm` section of the worker configuration (VM builds design, *Resources* and *Disk budget*). Its presence is
/// the switch: a worker with it runs every job in a VM, one without it builds on the host as before.
public struct VMSettings: Codable, Equatable, Sendable {
    /// Where images, slot states and job clones live: one APFS volume, since clones only work within a volume. An
    /// external SSD works. Default `~/.hangar/vm` of the worker's user.
    public var storage: String
    /// VMs at once. Apple allows two running macOS VMs per Mac, and a VM the owner runs takes one.
    public var slots: Int
    public var cpus: Int
    /// Part of each saved state: changing it re-saves the slots.
    public var memoryGB: Int
    /// A job still running after this long is stopped with its VM. There is no other job timeout.
    public var jobTimeoutMinutes: Int
    /// Free space on `storage` a job must leave: its growth (`jobReserveGB`) on top of the owner's floor.
    public var floorGB: Int
    public var jobReserveGB: Int

    public static let defaultSlots = 1
    public static let defaultCPUs = 4
    public static let defaultMemoryGB = 8
    public static let defaultJobTimeoutMinutes = 120
    public static let defaultFloorGB = 40
    public static let defaultJobReserveGB = 25

    public init(
        storage: String = VMSettings.defaultStorage(home: NSHomeDirectory()), slots: Int = VMSettings.defaultSlots,
        cpus: Int = VMSettings.defaultCPUs, memoryGB: Int = VMSettings.defaultMemoryGB,
        jobTimeoutMinutes: Int = VMSettings.defaultJobTimeoutMinutes, floorGB: Int = VMSettings.defaultFloorGB,
        jobReserveGB: Int = VMSettings.defaultJobReserveGB
    ) {
        self.storage = storage
        self.slots = slots
        self.cpus = cpus
        self.memoryGB = memoryGB
        self.jobTimeoutMinutes = jobTimeoutMinutes
        self.floorGB = floorGB
        self.jobReserveGB = jobReserveGB
    }

    public static func defaultStorage(home: String) -> String { home + "/.hangar/vm" }

    /// Every field but `storage` may be left out.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storage = try container.decode(String.self, forKey: .storage)
        slots = try container.decodeIfPresent(Int.self, forKey: .slots) ?? Self.defaultSlots
        cpus = try container.decodeIfPresent(Int.self, forKey: .cpus) ?? Self.defaultCPUs
        memoryGB = try container.decodeIfPresent(Int.self, forKey: .memoryGB) ?? Self.defaultMemoryGB
        jobTimeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .jobTimeoutMinutes) ?? Self.defaultJobTimeoutMinutes
        floorGB = try container.decodeIfPresent(Int.self, forKey: .floorGB) ?? Self.defaultFloorGB
        jobReserveGB = try container.decodeIfPresent(Int.self, forKey: .jobReserveGB) ?? Self.defaultJobReserveGB
    }

    /// What is wrong with the numbers, or nil. Slots cap at 2: Virtualization.framework refuses a third macOS VM.
    public var problem: String? {
        if storage.isEmpty || !storage.hasPrefix("/") { return "vm.storage must be an absolute path" }
        if storage.contains(where: \.isWhitespace) { return "vm.storage must not contain spaces" }
        if !(1...2).contains(slots) { return "vm.slots must be 1 or 2: macOS runs at most two macOS VMs at once" }
        if cpus < 2 { return "vm.cpus must be at least 2" }
        if memoryGB < 4 { return "vm.memoryGB must be at least 4" }
        if jobTimeoutMinutes < 1 { return "vm.jobTimeoutMinutes must be at least 1" }
        return nil
    }

    public var memoryBytes: UInt64 { UInt64(memoryGB) * 1024 * 1024 * 1024 }
}
