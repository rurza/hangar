import Foundation
import HangarCore
import Logging
import Synchronization

/// What the host hands the guest for one job (VM builds design, *Per-job lifecycle*, step 4). It travels as the first
/// line of the SSH session's standard input, never as a file in the share or a command-line argument: it holds the
/// job's variables, its token and the signing identity. Never the server's App Store Connect key: the host removes
/// it from the assignment, and exports and uploads an archive itself.
public struct GuestJobBundle: Codable, Equatable, Sendable {
    public var assignment: JobAssignment
    /// Works only for this job's worker routes, through the relay.
    public var token: String
    /// The relay as the guest sees it: `http://127.0.0.1:<port>`.
    public var serverURL: URL
    public var identity: GuestIdentity?
    /// For the job log: how the VM came up ("restored slot 0's saved state in 4.5 s").
    public var vmNote: String?
    /// The host's name, for failure reasons ("rurzobuk-max (VM)").
    public var machineName: String
    /// How an archive signs for development: the server's profiles, or the development key when one is missing.
    public var signing: JobRunner.GuestSigning?
    /// An archive stops after `post-xcodebuild` and hands off; the host exports it. False only for a host too old to.
    public var handsOffArchive: Bool

    public init(
        assignment: JobAssignment, token: String, serverURL: URL, identity: GuestIdentity?, vmNote: String?,
        machineName: String, signing: JobRunner.GuestSigning? = nil, handsOffArchive: Bool = true
    ) {
        self.signing = signing
        self.handsOffArchive = handsOffArchive
        self.assignment = assignment
        self.token = token
        self.serverURL = serverURL
        self.identity = identity
        self.vmNote = vmNote
        self.machineName = machineName
    }

    /// Variables every VM job gets: Homebrew does not update itself in the middle of a build, and sends no analytics.
    static let homebrewEnvironment = [
        EnvEntry(name: "HOMEBREW_NO_AUTO_UPDATE", value: "1"), EnvEntry(name: "HOMEBREW_NO_ANALYTICS", value: "1"),
        EnvEntry(name: "HOMEBREW_NO_INSTALL_CLEANUP", value: "1"),
    ]
}

/// The control lines that follow the bundle on standard input.
public enum GuestControl: Equatable, Sendable {
    /// The job was cancelled (from Hangar, or the host's timeout); the reason, when there is one, is the job's result.
    case cancel(reason: String?)

    public var line: String {
        switch self {
        case .cancel(let reason?): "cancel " + reason.replacingOccurrences(of: "\n", with: " ")
        case .cancel(nil): "cancel"
        }
    }

    public init?(line: String) {
        if line == "cancel" { self = .cancel(reason: nil) }
        else if line.hasPrefix("cancel ") { self = .cancel(reason: String(line.dropFirst("cancel ".count))) }
        else { return nil }
    }
}

/// The guest's side: `hangar-worker vm run-job`, as the build user, in a fresh clone. It runs the existing pipeline
/// against its own disk with the job's token, and prints the outcome as the last line of standard output, which the
/// host reads: the result (`hangar-result {json}`), or for an archive that got through `post-xcodebuild`, what the
/// host needs to export it (`hangar-handoff {json}`).
public struct GuestJobRunner: Sendable {
    public static let resultPrefix = "hangar-result "
    public static let handOffPrefix = "hangar-handoff "

    private let runner: any ProcessRunner
    private let home: String
    private let logger = Logger(label: "app.hangar.worker.guest")

    public init(runner: any ProcessRunner = LiveProcessRunner(), home: String = NSHomeDirectory()) {
        self.runner = runner
        self.home = home
    }

    /// The data directory in the guest: the image's workspace volume (Xcode Cloud's `/Volumes/workspace`), which holds
    /// the disk's room for jobs; else in the home. No spaces, as Xcode Cloud scripts expect.
    public var dataDirectory: String {
        FileManager.default.isWritableFile(atPath: Self.workspaceVolume) ? Self.workspaceVolume + "/hangar" : home + "/hangar"
    }

    public static let workspaceVolume = "/Volumes/workspace"

    /// Runs the job described by `bundle`. `cancelled` and `stopReason` come from the host's control lines.
    public func run(
        _ bundle: GuestJobBundle, cancelled: @escaping @Sendable () -> Bool, stopReason: @escaping @Sendable () -> String?,
        connection makeConnection: (URL, String) -> any ServerConnection = { HTTPServerConnection(baseURL: $0, token: $1) }
    ) async -> GuestRunOutcome {
        let connection = makeConnection(bundle.serverURL, bundle.token)
        var assignment = bundle.assignment
        // Never in a guest, even from a host that forgot to remove it.
        assignment.appStoreConnectKey = nil
        let signing = bundle.signing ?? JobRunner.GuestSigning()
        do {
            try Self.installProfiles(signing.profiles, home: home)
        } catch {
            logger.error("could not install the development profiles: \(error)")
        }
        let names = Set(assignment.environment.map(\.name))
        assignment.environment += GuestJobBundle.homebrewEnvironment.filter { !names.contains($0.name) }
        let keychain: CIKeychain?
        do {
            keychain = try await GuestKeychain.install(bundle.identity, directory: home + "/.hangar-keychain", runner: runner)
        } catch {
            // The pipeline reports it: the checkout step unlocks the keychain first and fails with the reason.
            logger.error("could not set up the job's keychain: \(error)")
            keychain = CIKeychain(path: home + "/.hangar-keychain/job.keychain-db", passwordFile: home + "/.hangar-keychain/missing")
        }
        let jobRunner = JobRunner(
            connection: connection, runner: runner, locator: XcodeLocator(runner: runner), dataDirectory: dataDirectory,
            machineName: bundle.machineName, keychain: keychain, preparationNote: bundle.vmNote,
            mode: bundle.handsOffArchive ? .guest(signing) : .standard)
        return await jobRunner.execute(assignment, cancelled: cancelled, stopReason: stopReason)
    }

    /// Where Xcode looks for installed profiles: `UserData/Provisioning Profiles` since Xcode 16, `MobileDevice`
    /// before. Each is written into both, named by its UUID.
    static func profileDirectories(home: String) -> [String] {
        [home + "/Library/Developer/Xcode/UserData/Provisioning Profiles", home + "/Library/MobileDevice/Provisioning Profiles"]
    }

    static func installProfiles(_ profiles: [JobProvisioningProfile], home: String) throws {
        guard !profiles.isEmpty else { return }
        for directory in profileDirectories(home: home) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for profile in profiles {
                // The UUID names the file: only its own characters.
                let name = profile.uuid.filter { $0.isASCII && ($0.isHexDigit || $0 == "-") }
                guard !name.isEmpty else { continue }
                try profile.content.write(
                    to: URL(fileURLWithPath: directory + "/" + name + (profile.isMac ? ".provisionprofile" : ".mobileprovision")))
            }
        }
    }

    /// The line the host parses.
    public static func outcomeLine(_ outcome: GuestRunOutcome) -> String {
        switch outcome {
        case .finished(let result): return resultLine(result)
        case .handOff(let handOff):
            let data = (try? JSONCoding.encoder.encode(handOff)) ?? Data("{}".utf8)
            return handOffPrefix + String(decoding: data, as: UTF8.self)
        }
    }

    public static func parseHandOff(_ line: String) -> ArchiveHandOff? {
        guard line.hasPrefix(handOffPrefix) else { return nil }
        return try? JSONCoding.decoder.decode(ArchiveHandOff.self, from: Data(line.dropFirst(handOffPrefix.count).utf8))
    }

    /// The line the host parses.
    public static func resultLine(_ result: JobResult) -> String {
        let data = (try? JSONCoding.encoder.encode(result)) ?? Data("{}".utf8)
        return resultPrefix + String(decoding: data, as: UTF8.self)
    }

    public static func parseResult(_ line: String) -> JobResult? {
        guard line.hasPrefix(resultPrefix) else { return nil }
        return try? JSONCoding.decoder.decode(JobResult.self, from: Data(line.dropFirst(resultPrefix.count).utf8))
    }
}

/// Reads the bundle and then the control lines from standard input. EOF means the host is gone: the job is cancelled.
public final class GuestControlReader: Sendable {
    private struct State {
        var cancelled = false
        var reason: String?
    }

    private let state = Mutex(State())

    public init() {}

    public var isCancelled: Bool { state.withLock { $0.cancelled } }
    public var stopReason: String? { state.withLock { $0.reason } }

    public func apply(_ control: GuestControl) {
        switch control {
        case .cancel(let reason):
            state.withLock {
                $0.cancelled = true
                if $0.reason == nil { $0.reason = reason }
            }
        }
    }

    /// The host went away (standard input closed).
    public func hostGone() {
        apply(.cancel(reason: "the build VM lost its connection to the host's worker"))
    }

    /// Reads the first line of `handle` as the bundle, then keeps reading control lines on a background thread.
    public func readBundle(from handle: FileHandle = .standardInput) throws -> GuestJobBundle {
        var buffer = Data()
        while true {
            let chunk = handle.readData(ofLength: 1)
            guard !chunk.isEmpty else { throw GuestBundleError.noBundle }
            if chunk == Data([0x0A]) { break }
            buffer.append(chunk)
        }
        let bundle = try JSONCoding.decoder.decode(GuestJobBundle.self, from: buffer)
        Thread.detachNewThread { [self] in
            var line = Data()
            while true {
                let chunk = handle.readData(ofLength: 1)
                if chunk.isEmpty {
                    hostGone()
                    return
                }
                if chunk == Data([0x0A]) {
                    if let control = GuestControl(line: String(decoding: line, as: UTF8.self)) { apply(control) }
                    line.removeAll()
                } else {
                    line.append(chunk)
                }
            }
        }
        return bundle
    }
}

public enum GuestBundleError: Error, CustomStringConvertible {
    case noBundle

    public var description: String { "no job bundle on standard input" }
}
