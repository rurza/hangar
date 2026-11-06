import Foundation
import HangarCore

/// The worker `sudo hangar-worker vm setup` sets up: the user it runs as, its binary and configuration, and its
/// launchd job. Either the dedicated `hangar` user's LaunchDaemon or the administrator's own launch agent.
public struct VMSetupTarget: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `/Library/LaunchDaemons/app.hangar.worker.plist`, running as `user` from boot.
        case daemon
        /// `~/Library/LaunchAgents/app.hangar.worker.plist` of `user`, whose uid it is.
        case agent(uid: UInt32)
    }

    public var user: String
    public var home: String
    public var binary: String
    public var config: String
    public var kind: Kind

    public init(user: String, home: String, binary: String, config: String, kind: Kind) {
        self.user = user
        self.home = home
        self.binary = binary
        self.config = config
        self.kind = kind
    }

    public var launchdTarget: String {
        switch kind {
        case .daemon: "system/" + WorkerLaunchDaemon.label
        case .agent(let uid): "gui/\(uid)/" + WorkerLaunchAgent.label
        }
    }

    /// How its commands are typed in an administrator's Terminal.
    public var commands: WorkerCommandLine { WorkerCommandLine(binary: binary, user: user) }

    /// The argv that runs `hangar-worker <arguments>` as the worker's user, from root (no password asked).
    public func asWorker(_ arguments: [String]) -> [String] {
        ["/usr/bin/sudo", "-u", user, "-H", binary] + arguments
    }

    public static func defaultConfig(home: String) -> String {
        home + "/Library/Application Support/Hangar/worker/config.json"
    }

    /// The hangar user's LaunchDaemon when it is installed, else `invoker`'s launch agent (an owner-run worker).
    /// `config` overrides the configuration the plist names. Nil when neither is there.
    public static func detect(
        daemonPlist: String, invoker: (name: String, uid: UInt32, home: String)?, config: String?,
        home: (String) -> String?
    ) -> VMSetupTarget? {
        if let plist = readPlist(daemonPlist), let user = plist.user, let userHome = home(user) {
            return VMSetupTarget(
                user: user, home: userHome, binary: plist.program,
                config: config ?? plist.config ?? defaultConfig(home: userHome), kind: .daemon)
        }
        guard let invoker else { return nil }
        let agentPlist = invoker.home + "/Library/LaunchAgents/" + WorkerLaunchAgent.label + ".plist"
        guard let plist = readPlist(agentPlist) else { return nil }
        return VMSetupTarget(
            user: invoker.name, home: invoker.home, binary: plist.program,
            config: config ?? plist.config ?? defaultConfig(home: invoker.home), kind: .agent(uid: invoker.uid))
    }

    static func readPlist(_ path: String) -> (program: String, config: String?, user: String?)? {
        guard let data = FileManager.default.contents(atPath: path),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let arguments = plist["ProgramArguments"] as? [String], let program = arguments.first
        else { return nil }
        var config: String?
        if let index = arguments.firstIndex(of: "--config"), index + 1 < arguments.count { config = arguments[index + 1] }
        return (program, config, plist["UserName"] as? String)
    }
}

/// An Xcode on this Mac: the one a job image is built from.
public struct VMSetupXcode: Sendable, Equatable {
    public var path: String
    public var version: String
    public var build: String

    public init(path: String, version: String, build: String) {
        self.path = path
        self.version = version
        self.build = build
    }

    /// `/Applications/Xcode.app` when it is there, else the newest `/Applications/Xcode*.app` (as xcodes names
    /// them, e.g. Xcode-27.2.0.app); nil when there is none.
    public static func find(in directory: String = "/Applications") -> VMSetupXcode? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let found = names.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.compactMap { name -> VMSetupXcode? in
            let path = directory + "/" + name
            guard let (version, build) = try? VMImageBuilder.xcodeVersion(at: path) else { return nil }
            return VMSetupXcode(path: path, version: version, build: build)
        }
        if let standard = found.first(where: { $0.path == directory + "/Xcode.app" }) { return standard }
        return found.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }
}

/// What `vm setup` found on this Mac before changing anything.
public struct VMSetupFacts: Sendable {
    public var target: VMSetupTarget
    /// The `vm` section the worker should have: the configuration's, with the command's options applied.
    public var settings: VMSettings
    /// The configuration's `vm` section now; nil while VM builds are off.
    public var currentSettings: VMSettings?
    public var xcode: VMSetupXcode?
    public var licenseAccepted: Bool
    /// The network filter's problem, nil when it is loaded.
    public var filterProblem: String?
    public var images: [VMImageMetadata]
    public var storageExists: Bool
    /// The mount point of an external volume that ignores ownership, which the storage is on.
    public var volumeIgnoringOwnership: String?

    public init(
        target: VMSetupTarget, settings: VMSettings, currentSettings: VMSettings?, xcode: VMSetupXcode?,
        licenseAccepted: Bool, filterProblem: String?, images: [VMImageMetadata], storageExists: Bool,
        volumeIgnoringOwnership: String? = nil
    ) {
        self.target = target
        self.settings = settings
        self.currentSettings = currentSettings
        self.xcode = xcode
        self.licenseAccepted = licenseAccepted
        self.filterProblem = filterProblem
        self.images = images
        self.storageExists = storageExists
        self.volumeIgnoringOwnership = volumeIgnoringOwnership
    }

    /// The job image made from this Mac's Xcode (same build, or the same version when the image has no build).
    public var imageForXcode: VMImageMetadata? {
        guard let xcode else { return nil }
        return images.first { image in
            image.isJobImage && (image.xcodeBuild.map { $0 == xcode.build } ?? (image.xcode == xcode.version))
        }
    }

    /// The newest base (vanilla) image, to build from.
    public var newestBaseImage: VMImageMetadata? { Self.newestBaseImage(in: images) }

    public static func newestBaseImage(in images: [VMImageMetadata]) -> VMImageMetadata? {
        images.filter { !$0.isJobImage }.max { $0.createdAt < $1.createdAt }
    }
}

/// One thing `vm setup` does.
public enum VMSetupAction: Sendable, Equatable {
    /// Runs a command (as root, or as the worker's user through `sudo -u`), its output shown as it comes.
    case run([String])
    case installNetworkFilter
    /// SIGTERM to the worker's launchd job, which starts it again; a kickstart when it was not running.
    case restartWorker
}

public struct VMSetupStep: Sendable, Equatable {
    public var title: String
    /// What it costs, e.g. "about 5 minutes, 26 GB"; nil for a quick step.
    public var estimate: String?
    /// Nothing to do: why ("already loaded").
    public var done: String?
    public var actions: [VMSetupAction]

    public init(title: String, estimate: String? = nil, done: String? = nil, actions: [VMSetupAction] = []) {
        self.title = title
        self.estimate = estimate
        self.done = done
        self.actions = actions
    }
}

/// `sudo hangar-worker vm setup`: everything VM builds need on this Mac, in one sudo session, safe to run again
/// (VM builds design; the onboarding review's change #6). Root does what needs root (sleep settings, the Xcode
/// license, the storage's ownership, the network filter, the worker's restart); the worker's own files (its
/// configuration, the images) are made by the worker's user through `sudo -u`, so they stay that user's.
public enum VMSetup {
    /// About how much a fresh vanilla import takes on disk.
    public static let baseImageGB = 26
    /// About how much a job image adds to its base (APFS clone plus Xcode).
    public static let jobImageGB = 6

    /// The free space VM builds need on the storage volume beyond what is there: the images still to make, a saved
    /// state per slot (up to its memory), one job's growth and the floor.
    public static func requiredFreeGB(settings: VMSettings, needsBaseImage: Bool, needsJobImage: Bool) -> Int {
        (needsBaseImage ? baseImageGB : 0) + (needsJobImage ? jobImageGB : 0) + settings.slots * settings.memoryGB
            + settings.jobReserveGB + settings.floorGB
    }

    /// The guest's macOS ("26.6.2") of the default import; the host must be at least as new to run it.
    public static var defaultGuestMacOS: String {
        OCIReference(VMImageImporter.defaultVanilla)?.tag ?? "26.6.2"
    }

    public static func plan(_ facts: VMSetupFacts) -> [VMSetupStep] {
        let target = facts.target
        let settings = facts.settings
        var steps: [VMSetupStep] = []

        steps.append(VMSetupStep(
            title: "Keep this Mac awake (sleep stops builds)",
            actions: [.run(["/usr/bin/pmset", "-a", "sleep", "0", "disksleep", "0"])]))

        if let xcode = facts.xcode, !facts.licenseAccepted {
            steps.append(VMSetupStep(
                title: "Accept the Xcode license",
                actions: [.run([xcode.path + "/Contents/Developer/usr/bin/xcodebuild", "-license", "accept"])]))
        } else {
            steps.append(VMSetupStep(title: "Accept the Xcode license", done: "already accepted"))
        }

        // Storage inside the worker's home is created by `vm enable` as the worker's user; elsewhere (an external
        // SSD) root makes the directory and gives it to that user, and turns on the volume's ownership.
        var storage: [VMSetupAction] = []
        if let volume = facts.volumeIgnoringOwnership {
            storage.append(.run(["/usr/sbin/diskutil", "enableOwnership", volume]))
        }
        if !facts.storageExists, !settings.storage.hasPrefix(target.home + "/") {
            storage += [
                .run(["/bin/mkdir", "-p", settings.storage]),
                .run(["/usr/sbin/chown", target.user + ":staff", settings.storage]),
                .run(["/bin/chmod", "700", settings.storage]),
            ]
        }
        steps.append(VMSetupStep(
            title: "VM storage at \(settings.storage)",
            done: storage.isEmpty ? (facts.storageExists ? "ready" : "the worker's user creates it next") : nil,
            actions: storage))

        if facts.currentSettings != settings {
            var enable = ["vm", "enable", "--config", target.config, "--storage", settings.storage]
            enable += ["--slots", String(settings.slots), "--cpus", String(settings.cpus), "--memory-gb", String(settings.memoryGB)]
            // Restarted at once, so the worker stops taking host builds; it takes none until the rest is ready.
            steps.append(VMSetupStep(
                title: "Turn VM builds on, and restart the worker so it stops building on this Mac itself",
                actions: [.run(target.asWorker(enable)), .restartWorker]))
        } else {
            steps.append(VMSetupStep(title: "Turn VM builds on", done: "already on"))
        }

        steps.append(VMSetupStep(
            title: "Install the network filter that keeps VMs off this Mac, the LAN and the tailnet",
            done: facts.filterProblem == nil ? "already loaded" : nil,
            actions: facts.filterProblem == nil ? [] : [.installNetworkFilter]))

        let needsJobImage = facts.imageForXcode == nil
        let base = facts.newestBaseImage
        let defaultBase = "vanilla-" + defaultGuestMacOS
        if needsJobImage, base == nil {
            steps.append(VMSetupStep(
                title: "Download the macOS image (\(defaultBase))", estimate: "about 5 minutes, \(baseImageGB) GB",
                actions: [.run(target.asWorker(["vm", "image", "import", "--config", target.config]))]))
        } else {
            steps.append(VMSetupStep(
                title: "Download the macOS image",
                done: needsJobImage ? "\(base!.name) is here" : "not needed: the Xcode image is here"))
        }

        if needsJobImage, let xcode = facts.xcode {
            // The slot states are left to the worker, which saves them when it starts, holding each slot.
            let build = ["vm", "image", "build", "--config", target.config, "--from", base?.name ?? defaultBase]
                + ["--xcode", xcode.path, "--skip-slots"]
            steps.append(VMSetupStep(
                title: "Build the job image with Xcode \(xcode.version)", estimate: "about 10 minutes",
                actions: [.run(target.asWorker(build))]))
        } else {
            steps.append(VMSetupStep(
                title: "Build the job image", done: facts.imageForXcode.map { "\($0.name) is here" } ?? "no Xcode"))
        }

        // Only after a change: on a Mac that is set up already, a restart would only cancel a running build.
        let changed = steps.dropFirst(3).contains { $0.done == nil }
        steps.append(VMSetupStep(
            title: "Restart the worker; it saves each slot's state when it starts (about a minute a slot)",
            done: changed ? nil : "not needed: nothing changed", actions: changed ? [.restartWorker] : []))
        return steps
    }
}
