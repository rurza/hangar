import Foundation

/// Everything a VM is made from. A restore needs every field identical to the save, except the directory behind
/// `share` (same tag, different host directory works) and the disk and NVRAM paths (clones of the saved ones).
public struct VMSpec: Sendable, Equatable {
    public var hardwareModel: Data
    public var machineIdentifier: Data
    public var disk: String
    public var nvram: String
    public var cpus: Int
    public var memoryBytes: UInt64
    public var macAddress: String
    /// Read-only in the guest under the tag `hangar`. Always present, so states saved with it restore with it.
    public var share: String

    public init(
        hardwareModel: Data, machineIdentifier: Data, disk: String, nvram: String, cpus: Int, memoryBytes: UInt64,
        macAddress: String, share: String
    ) {
        self.hardwareModel = hardwareModel
        self.machineIdentifier = machineIdentifier
        self.disk = disk
        self.nvram = nvram
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.macAddress = macAddress
        self.share = share
    }

    public static let shareTag = "hangar"
}

/// The failures that decide what the worker does next (VM builds design, *Engine*).
public enum VMError: Error, Equatable, CustomStringConvertible {
    /// The binary lacks `com.apple.security.virtualization`.
    case entitlementMissing
    /// "Invalid argument" on restore: the state does not fit this configuration or this host any more. Cold boot.
    case stateIncompatible(String)
    /// Apple's limit of two running macOS VMs is reached, possibly by a VM the owner runs. The slot counts as busy.
    case tooManyVMs
    case invalidConfiguration(String)
    case failed(String)

    public var description: String {
        switch self {
        case .entitlementMissing:
            "hangar-worker is not signed with the com.apple.security.virtualization entitlement: reinstall the server with the latest scripts/server/install-server.sh (it signs the hangar-worker it hands out), then run the install command from Machines › Add Mac again"
        case .stateIncompatible(let detail): "the saved VM state does not fit any more (\(detail))"
        case .tooManyVMs: "this Mac already runs two macOS VMs, the most macOS allows"
        case .invalidConfiguration(let detail): "the VM configuration is invalid: \(detail)"
        case .failed(let detail): detail
        }
    }
}

/// How a VM ended on its own.
public enum VMStop: Sendable, Equatable {
    /// The guest shut down.
    case guestStopped
    case error(String)
}

/// One VM. Every method may be called from any task; the implementation serializes them on the VM's queue.
public protocol VirtualMachine: AnyObject, Sendable {
    /// Cold boot.
    func start() async throws
    /// Restores `state` and resumes the guest. `VMError.stateIncompatible` when the state does not fit.
    func restore(from state: String) async throws
    /// Pauses the guest and writes its memory and device state to `path`. The VM stays paused.
    func save(to path: String) async throws
    /// A hard stop; nothing in a job's guest is worth a clean shutdown. Never throws: it is the cleanup path.
    func stop() async
    /// Called once, from any thread, when the VM stops without `stop()`.
    func onStop(_ handler: @escaping @Sendable (VMStop) -> Void)
}

/// Makes VMs; the seam that keeps Virtualization.framework out of the tests.
public protocol VirtualMachineEngine: Sendable {
    func make(_ spec: VMSpec) throws -> any VirtualMachine
    /// A new `VZMacMachineIdentifier.dataRepresentation`.
    func newMachineIdentifier() -> Data
    /// Nil when this process may run VMs, else why not (the entitlement).
    func unavailableReason() -> String?
}
