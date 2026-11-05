import Foundation
import Synchronization
@preconcurrency import Virtualization

/// `VirtualMachineEngine` on Virtualization.framework. The process needs the `com.apple.security.virtualization`
/// entitlement (an ad hoc signature carries it; see `scripts/worker/hangar-worker.entitlements`).
public struct LiveVirtualMachineEngine: VirtualMachineEngine {
    public init() {}

    public func make(_ spec: VMSpec) throws -> any VirtualMachine {
        try LiveVirtualMachine(configuration: Self.configuration(spec))
    }

    public func newMachineIdentifier() -> Data { VZMacMachineIdentifier().dataRepresentation }

    /// Asks Virtualization.framework itself: the configuration check names the missing entitlement.
    public func unavailableReason() -> String? {
        guard VZVirtualMachine.isSupported else { return "this Mac does not support virtualization" }
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        configuration.memorySize = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        do {
            try configuration.validate()
        } catch {
            if "\(error)".contains("com.apple.security.virtualization") { return VMError.entitlementMissing.description }
        }
        return nil
    }

    /// The spike's configuration: macOS platform, raw disk, NAT, one virtio-fs share, entropy, a vsock device and a
    /// balloon (configured, unused), keyboard, pointer and a display (a GUI session expects one).
    static func configuration(_ spec: VMSpec) throws -> VZVirtualMachineConfiguration {
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: spec.hardwareModel) else {
            throw VMError.invalidConfiguration("the image's hardware model is unreadable")
        }
        guard hardwareModel.isSupported else {
            throw VMError.invalidConfiguration("this Mac cannot run the image's hardware model")
        }
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: spec.machineIdentifier) else {
            throw VMError.invalidConfiguration("the machine identifier is unreadable")
        }
        guard let mac = VZMACAddress(string: spec.macAddress) else {
            throw VMError.invalidConfiguration("\(spec.macAddress) is not a MAC address")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: URL(fileURLWithPath: spec.nvram))

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = spec.cpus
        configuration.memorySize = spec.memoryBytes
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 80)]
        configuration.graphicsDevices = [graphics]
        do {
            let disk = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: spec.disk), readOnly: false, cachingMode: .automatic, synchronizationMode: .fsync)
            configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        } catch {
            throw VMError.invalidConfiguration("cannot open the disk \(spec.disk): \(error.localizedDescription)")
        }
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = mac
        configuration.networkDevices = [network]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        let share = VZVirtioFileSystemDeviceConfiguration(tag: VMSpec.shareTag)
        share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: spec.share), readOnly: true))
        configuration.directorySharingDevices = [share]
        do {
            try configuration.validate()
            try configuration.validateSaveRestoreSupport()
        } catch {
            if "\(error)".contains("com.apple.security.virtualization") { throw VMError.entitlementMissing }
            throw VMError.invalidConfiguration(error.localizedDescription)
        }
        return configuration
    }

    /// The typed failure for a Virtualization.framework error.
    static func map(_ error: any Error, restoring: Bool = false) -> VMError {
        let error = error as NSError
        guard error.domain == VZErrorDomain else { return .failed(error.localizedDescription) }
        switch error.code {
        case VZError.Code.virtualMachineLimitExceeded.rawValue: return .tooManyVMs
        case VZError.Code.restore.rawValue where restoring: return .stateIncompatible(error.localizedDescription)
        default: return .failed("\(error.localizedDescription) (VZErrorDomain \(error.code))")
        }
    }
}

/// One `VZVirtualMachine`, used only on its own serial queue.
final class LiveVirtualMachine: NSObject, VirtualMachine, VZVirtualMachineDelegate, @unchecked Sendable {
    private let queue: DispatchQueue
    // Only touched on `queue`.
    private let machine: VZVirtualMachine
    private let stopHandler = Mutex<(@Sendable (VMStop) -> Void)?>(nil)
    private let stopping = Mutex(false)

    init(configuration: VZVirtualMachineConfiguration) throws {
        let queue = DispatchQueue(label: "app.hangar.vm")
        self.queue = queue
        machine = queue.sync { VZVirtualMachine(configuration: configuration, queue: queue) }
        super.init()
        queue.sync { machine.delegate = self }
    }

    func start() async throws {
        try await perform { machine, done in machine.start { done($0.error) } }
    }

    func restore(from state: String) async throws {
        try await perform(restoring: true) { machine, done in
            machine.restoreMachineStateFrom(url: URL(fileURLWithPath: state)) { done($0) }
        }
        try await perform { machine, done in machine.resume { done($0.error) } }
    }

    func save(to path: String) async throws {
        try await perform { machine, done in
            machine.pause { result in
                if let error = result.error { return done(error) }
                machine.saveMachineStateTo(url: URL(fileURLWithPath: path)) { done($0) }
            }
        }
    }

    func stop() async {
        stopping.withLock { $0 = true }
        try? await perform { machine, done in
            guard machine.canStop else { return done(nil) }
            machine.stop { done($0) }
        }
    }

    func onStop(_ handler: @escaping @Sendable (VMStop) -> Void) {
        stopHandler.withLock { $0 = handler }
    }

    // MARK: VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { report(.guestStopped) }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        report(.error(error.localizedDescription))
    }

    private func report(_ stop: VMStop) {
        guard !stopping.withLock({ $0 }) else { return }
        let handler = stopHandler.withLock { handler in
            defer { handler = nil }
            return handler
        }
        handler?(stop)
    }

    // MARK: Plumbing

    /// Runs `body` on the VM's queue; it calls `done` once, with the error or nil.
    private func perform(
        restoring: Bool = false, _ body: @escaping (VZVirtualMachine, @escaping (Error?) -> Void) -> Void
    ) async throws {
        nonisolated(unsafe) let body = body
        nonisolated(unsafe) let machine = machine
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                body(machine) { error in
                    if let error {
                        continuation.resume(throwing: error is VMError ? error : LiveVirtualMachineEngine.map(error, restoring: restoring))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
}

private extension Result where Success == Void {
    var error: (any Error)? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
