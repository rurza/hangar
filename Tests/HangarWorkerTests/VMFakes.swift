import Foundation
import HangarCore
import Synchronization

@testable import HangarWorker

/// A VM that records what it was asked to do. `restoreError` and `startError` make those calls fail.
final class FakeVM: VirtualMachine {
    enum Call: Equatable {
        case start
        case restore(String)
        case save(String)
        case stop
    }

    let spec: VMSpec
    private let state = Mutex<(calls: [Call], handler: (@Sendable (VMStop) -> Void)?)>(([], nil))
    let restoreError: VMError?
    let startError: VMError?

    init(spec: VMSpec, restoreError: VMError? = nil, startError: VMError? = nil) {
        self.spec = spec
        self.restoreError = restoreError
        self.startError = startError
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func start() async throws {
        state.withLock { $0.calls.append(.start) }
        if let startError { throw startError }
    }

    func restore(from path: String) async throws {
        state.withLock { $0.calls.append(.restore(path)) }
        if let restoreError { throw restoreError }
    }

    func save(to path: String) async throws {
        state.withLock { $0.calls.append(.save(path)) }
        FileManager.default.createFile(atPath: path, contents: Data("state".utf8))
    }

    func stop() async { state.withLock { $0.calls.append(.stop) } }

    func onStop(_ handler: @escaping @Sendable (VMStop) -> Void) { state.withLock { $0.handler = handler } }

    /// The guest stops on its own (it shut down, or crashed).
    func stopOnItsOwn(_ stop: VMStop) {
        let handler = state.withLock { $0.handler }
        handler?(stop)
    }
}

/// Makes `FakeVM`s; `restoreErrors` fail the restores in order.
final class FakeEngine: VirtualMachineEngine {
    private let state = Mutex<(machines: [FakeVM], restoreErrors: [VMError], startErrors: [VMError])>(([], [], []))
    let unavailable: String?

    init(restoreErrors: [VMError] = [], startErrors: [VMError] = [], unavailable: String? = nil) {
        state.withLock {
            $0.restoreErrors = restoreErrors
            $0.startErrors = startErrors
        }
        self.unavailable = unavailable
    }

    var machines: [FakeVM] { state.withLock { $0.machines } }

    func make(_ spec: VMSpec) throws -> any VirtualMachine {
        state.withLock { state in
            let machine = FakeVM(
                spec: spec, restoreError: state.restoreErrors.isEmpty ? nil : state.restoreErrors.removeFirst(),
                startError: state.startErrors.isEmpty ? nil : state.startErrors.removeFirst())
            state.machines.append(machine)
            return machine
        }
    }

    func newMachineIdentifier() -> Data { Data(UUID().uuidString.utf8) }

    func unavailableReason() -> String? { unavailable }
}

/// A guest session that records the lines it was sent and ends when the test says so.
final class FakeGuestSession: GuestSession {
    private struct State {
        var sent: [String] = []
        var exitCode: Int32?
        var terminated = false
        var waiters: [CheckedContinuation<Int32, Never>] = []
    }

    private let state = Mutex(State())
    let onLine: @Sendable (String) -> Void
    /// Called with every line sent; may answer by printing lines and ending.
    let script: @Sendable (FakeGuestSession, String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void, script: @escaping @Sendable (FakeGuestSession, String) -> Void) {
        self.onLine = onLine
        self.script = script
    }

    var sent: [String] { state.withLock { $0.sent } }
    var wasTerminated: Bool { state.withLock { $0.terminated } }

    func send(_ line: SensitiveText) {
        let ended = state.withLock { state -> Bool in
            guard state.exitCode == nil else { return true }
            state.sent.append(line.value)
            return false
        }
        if !ended { script(self, line.value) }
    }

    func terminate() {
        state.withLock { $0.terminated = true }
        end(143)
    }

    func print(_ line: String) { onLine(line) }

    func end(_ code: Int32) {
        let waiters = state.withLock { state -> [CheckedContinuation<Int32, Never>] in
            guard state.exitCode == nil else { return [] }
            state.exitCode = code
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume(returning: code) }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let code = state.withLock { state -> Int32? in
                if let code = state.exitCode { return code }
                state.waiters.append(continuation)
                return nil
            }
            if let code { continuation.resume(returning: code) }
        }
    }
}

final class FakeSessionLauncher: GuestSessionLaunching {
    private let state = Mutex<(commands: [ProcessCommand], sessions: [FakeGuestSession])>(([], []))
    let script: @Sendable (FakeGuestSession, String) -> Void

    init(script: @escaping @Sendable (FakeGuestSession, String) -> Void) { self.script = script }

    var commands: [ProcessCommand] { state.withLock { $0.commands } }
    var sessions: [FakeGuestSession] { state.withLock { $0.sessions } }

    func launch(_ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void) throws -> any GuestSession {
        let session = FakeGuestSession(onLine: onLine, script: script)
        state.withLock {
            $0.commands.append(command)
            $0.sessions.append(session)
        }
        return session
    }
}

/// `FakeServerConnection` plus job tokens.
final class FakeTokenConnection: ServerConnection, JobTokenIssuing {
    let base = FakeServerConnection()
    private let tokens = Mutex<(issued: [UUID], revoked: [UUID])>(([], []))

    var issued: [UUID] { tokens.withLock { $0.issued } }
    var revoked: [UUID] { tokens.withLock { $0.revoked } }

    func issueJobToken(jobID: UUID) async throws -> String {
        tokens.withLock { $0.issued.append(jobID) }
        return "hgj_job-token"
    }

    func revokeJobToken(jobID: UUID) async throws { tokens.withLock { $0.revoked.append(jobID) } }

    /// What `provisioning` answers: by default one profile for the app, nothing missing.
    let provisioningAnswer = Mutex<Result<JobProvisioning, ServerConnectionError>>(.success(JobProvisioning(profiles: [
        JobProvisioningProfile(bundleID: "com.acme.demo", name: "Hangar Development com.acme.demo", uuid: "1111-AAAA", isMac: false, content: Data("profile".utf8)),
    ])))
    private let provisioningAsked = Mutex<[JobProvisioningRequest]>([])
    var provisioningRequests: [JobProvisioningRequest] { provisioningAsked.withLock { $0 } }

    func provisioning(jobID: UUID, _ request: JobProvisioningRequest) async throws -> JobProvisioning {
        provisioningAsked.withLock { $0.append(request) }
        return try provisioningAnswer.withLock { try $0.get() }
    }

    func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse { try await base.heartbeat(request) }
    func nextJob(wait: Int) async throws -> JobAssignment? { nil }
    func start(jobID: UUID) async throws { try await base.start(jobID: jobID) }
    func step(jobID: UUID, _ update: StepUpdate) async throws { try await base.step(jobID: jobID, update) }
    func info(jobID: UUID, _ info: JobRunInfo) async throws { try await base.info(jobID: jobID, info) }
    func log(jobID: UUID, _ batch: LogBatch) async throws { try await base.log(jobID: jobID, batch) }
    func uploadArtifact(jobID: UUID, name: String, fileURL: URL) async throws {
        try await base.uploadArtifact(jobID: jobID, name: name, fileURL: fileURL)
    }
    func finish(jobID: UUID, _ result: JobResult) async throws { try await base.finish(jobID: jobID, result) }
}

/// A VM storage directory in the temporary directory (APFS, so clones work) with one image in it, and a DHCP leases
/// file that already holds every slot's address.
struct VMFixture {
    let root = NSTemporaryDirectory() + "hangar-vm-" + UUID().uuidString
    var storage: VMStorage { VMStorage(root: root + "/vm") }
    var leases: String { root + "/dhcpd_leases" }
    let machineName = "test-mac"

    init(buildUser: String? = "builder", xcode: String? = "27.2") throws {
        try storage.create()
        try FileManager.default.createDirectory(atPath: storage.image("xcode-27.2").path, withIntermediateDirectories: true)
        let image = storage.image("xcode-27.2")
        try Data("disk".utf8).write(to: URL(fileURLWithPath: image.disk))
        try Data("nvram".utf8).write(to: URL(fileURLWithPath: image.nvram))
        try VMBundleFile.write(
            TartConfig(
                cpuCountMin: 2, cpuCount: 4, memorySizeMin: 4 << 30, memorySize: 8 << 30, macAddress: "72:76:f4:5e:d8:14",
                hardwareModel: Data("hw".utf8).base64EncodedString(), ecid: Data("ecid".utf8).base64EncodedString()),
            to: image.config)
        try VMBundleFile.write(
            VMImageMetadata(
                name: "xcode-27.2", macOS: "26.6.2 (25G83)", xcode: xcode, xcodeBuild: "17C52", simulatorRuntimes: ["iOS 27.2"],
                source: "vanilla-26.6.2", createdAt: Date(timeIntervalSince1970: 0), buildUser: buildUser),
            to: image.metadata)
        var text = ""
        for slot in 0..<3 {
            let mac = VMMACAddress.leaseForm(VMMACAddress.forSlot(slot, machine: machineName))
            text += "{\n\tname=vm\n\tip_address=192.168.64.\(slot + 10)\n\thw_address=1,\(mac)\n\tidentifier=1,\(mac)\n\tlease=0x6a000000\n}\n"
        }
        try text.write(toFile: leases, atomically: true, encoding: .utf8)
    }

    func host(_ engine: FakeEngine, runner: some ProcessRunner = RecordingProcessRunner(), settings: VMSettings? = nil) -> VMHost {
        // No floor: the tests must not depend on this Mac's free space.
        var settings = settings ?? VMSettings(storage: storage.root, floorGB: 0, jobReserveGB: 0)
        settings.storage = storage.root
        return VMHost(
            settings: settings, engine: engine, runner: runner, machineName: machineName, hostBuild: "25G83",
            leasesFile: leases)
    }

    func image() throws -> VMImage { try VMImage(directory: storage.image("xcode-27.2")) }

    /// Writes a saved state for `slot` as `prepareSlot` would.
    func saveSlot(_ slot: Int, cpus: Int = 4, memoryGB: Int = 8, hostBuild: String = "25G83") throws {
        let image = try image()
        let directory = image.directory.slot(slot)
        try FileManager.default.createDirectory(atPath: directory.share, withIntermediateDirectories: true)
        for path in [directory.disk, directory.nvram, directory.state] {
            try Data("slot".utf8).write(to: URL(fileURLWithPath: path))
        }
        try VMBundleFile.write(
            VMSlotMetadata(
                macAddress: VMMACAddress.forSlot(slot, machine: machineName),
                machineIdentifier: Data("slot-\(slot)".utf8).base64EncodedString(), cpus: cpus, memoryGB: memoryGB,
                imageID: image.metadata.id, hostBuild: hostBuild, savedAt: Date(timeIntervalSince1970: 0)),
            to: directory.metadata)
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: root) }
}
