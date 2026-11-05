import Foundation
import HangarCore

/// Tart's `config.json`, so `tart run` opens a Hangar image and a Tart OCI image imports as it is. `hardwareModel`
/// and `ecid` are the base64 of `VZMacHardwareModel.dataRepresentation` and `VZMacMachineIdentifier.dataRepresentation`.
public struct TartConfig: Codable, Equatable, Sendable {
    public struct Display: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public var version: Int
    public var os: String
    public var arch: String
    public var cpuCountMin: Int
    public var cpuCount: Int
    public var memorySizeMin: UInt64
    public var memorySize: UInt64
    public var macAddress: String
    public var display: Display
    public var hardwareModel: String
    public var ecid: String
    public var diskFormat: String?

    public init(
        version: Int = 1, os: String = "darwin", arch: String = "arm64", cpuCountMin: Int, cpuCount: Int,
        memorySizeMin: UInt64, memorySize: UInt64, macAddress: String, display: Display = Display(width: 1024, height: 768),
        hardwareModel: String, ecid: String, diskFormat: String? = "raw"
    ) {
        self.version = version
        self.os = os
        self.arch = arch
        self.cpuCountMin = cpuCountMin
        self.cpuCount = cpuCount
        self.memorySizeMin = memorySizeMin
        self.memorySize = memorySize
        self.macAddress = macAddress
        self.display = display
        self.hardwareModel = hardwareModel
        self.ecid = ecid
        self.diskFormat = diskFormat
    }

    public var hardwareModelData: Data? { Data(base64Encoded: hardwareModel) }
    public var machineIdentifierData: Data? { Data(base64Encoded: ecid) }
}

/// Hangar's `image.json`: what the image holds and where it came from.
public struct VMImageMetadata: Codable, Equatable, Sendable {
    /// New for every import or build: a slot state saved from an older one is stale.
    public var id: UUID
    public var name: String
    /// "26.6.2 (25G83)"; empty until read from the guest.
    public var macOS: String
    public var xcode: String?
    public var xcodeBuild: String?
    public var simulatorRuntimes: [String]
    /// The OCI reference with its digest, or the image this one was built from.
    public var source: String
    public var createdAt: Date
    /// The user jobs run as; nil for a vanilla import, which is not a job image.
    public var buildUser: String?

    public init(
        id: UUID = UUID(), name: String, macOS: String = "", xcode: String? = nil, xcodeBuild: String? = nil,
        simulatorRuntimes: [String] = [], source: String, createdAt: Date, buildUser: String? = nil
    ) {
        self.id = id
        self.name = name
        self.macOS = macOS
        self.xcode = xcode
        self.xcodeBuild = xcodeBuild
        self.simulatorRuntimes = simulatorRuntimes
        self.source = source
        self.createdAt = createdAt
        self.buildUser = buildUser
    }

    public var info: VMImageInfo {
        VMImageInfo(name: name, macOS: macOS, xcode: xcode, xcodeBuild: xcodeBuild, simulatorRuntimes: simulatorRuntimes)
    }

    /// A job image has a build user; a vanilla import is only a base to build one from.
    public var isJobImage: Bool { buildUser != nil }
}

/// A slot's `slot.json`: the identity its state was saved with. A restore needs exactly this configuration.
public struct VMSlotMetadata: Codable, Equatable, Sendable {
    public var macAddress: String
    /// Base64 `VZMacMachineIdentifier.dataRepresentation`: its own per slot, so two restored VMs can run together.
    public var machineIdentifier: String
    public var cpus: Int
    public var memoryGB: Int
    /// The `VMImageMetadata.id` the state was saved from.
    public var imageID: UUID
    /// The host's macOS build when the state was saved: a host update can make a state unrestorable.
    public var hostBuild: String
    public var savedAt: Date

    public init(
        macAddress: String, machineIdentifier: String, cpus: Int, memoryGB: Int, imageID: UUID, hostBuild: String,
        savedAt: Date
    ) {
        self.macAddress = macAddress
        self.machineIdentifier = machineIdentifier
        self.cpus = cpus
        self.memoryGB = memoryGB
        self.imageID = imageID
        self.hostBuild = hostBuild
        self.savedAt = savedAt
    }

    /// Why this state cannot serve a job with these settings and image, or nil when it can.
    public func staleness(settings: VMSettings, image: VMImageMetadata, hostBuild: String) -> String? {
        if imageID != image.id { return "the image was rebuilt" }
        if cpus != settings.cpus || memoryGB != settings.memoryGB { return "the VM's CPUs or memory changed" }
        if self.hostBuild != hostBuild { return "macOS on this Mac was updated" }
        return nil
    }
}

/// Reading and writing the bundle's JSON files.
public enum VMBundleFile {
    public static func read<Value: Decodable>(_ type: Value.Type, at path: String) throws -> Value {
        guard let data = FileManager.default.contents(atPath: path) else { throw VMStorageError.unreadable(path) }
        return try JSONCoding.decoder.decode(type, from: data)
    }

    public static func write(_ value: some Encodable, to path: String) throws {
        let encoder = JSONCoding.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// Locally administered MAC addresses for slots: `02:68:67:<machine>:<slot>:00` ("hg"), one per slot and Mac.
public enum VMMACAddress {
    public static func forSlot(_ slot: Int, machine: String) -> String {
        let machineByte = SHA256File.hex(of: Data(machine.utf8)).prefix(2)
        return String(format: "02:68:67:%@:%02x:00", String(machineByte), slot & 0xff)
    }

    /// The form `/var/db/dhcpd_leases` writes: lowercase hex without leading zeros ("2:68:67:a:0:0").
    public static func leaseForm(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { part in
            Int(part, radix: 16).map { String($0, radix: 16) } ?? String(part)
        }.joined(separator: ":")
    }
}
