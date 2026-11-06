import ArgumentParser
import Foundation
import HangarCore
import HangarWorker

extension VMCommand {
    /// `sudo hangar-worker vm setup`: checks the Mac, then does every VM setup step in one sudo session (`VMSetup`).
    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Sets up VM builds on this Mac in one go (run it with sudo; safe to run again).",
            discussion: """
                Checks this Mac first (Apple silicon, macOS, Xcode and its license, free space, the server), then: \
                keeps the Mac awake, accepts the Xcode license, prepares the storage, turns VM builds on, installs the \
                network filter, downloads the macOS image, builds the job image with this Mac's Xcode, and restarts \
                the worker (your own launch agent, which the install command set up). Steps that are done already are skipped, so running it again finishes an interrupted setup.
                """)

        @Option(help: "The worker's configuration file. Default: the one its launchd job uses.")
        var config: String?
        @Option(help: "VM storage directory on an APFS volume (an external SSD works). Default: the configuration's, else ~/.hangar/vm of the worker's user.")
        var storage: String?
        @Option(help: "VMs at once (1 or 2).")
        var slots: Int?
        @Option(help: "Virtual CPUs per VM.")
        var cpus: Int?
        @Option(help: "Memory per VM in GB.")
        var memoryGb: Int?
        @Option(help: "The Xcode to build the job image with. Default: /Applications/Xcode.app, else the newest /Applications/Xcode*.app.")
        var xcode: String?
        @Flag(help: "Print the checks and the steps without changing anything (needs no sudo).")
        var dryRun = false

        func run() async throws {
            let environment = ProcessInfo.processInfo.environment
            let invoker = Self.invoker(environment)
            guard let target = VMSetupTarget.detect(
                invoker: invoker, config: config.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            else {
                throw VMCommand.fail("""
                    no worker is installed for \(invoker?.name ?? "you") on this Mac (no launch agent). Install it \
                    first: Hangar › Machines › Add Mac.
                    """)
            }
            if !dryRun, geteuid() != 0 {
                throw VMCommand.fail("run it with sudo: \(target.commands.vmSetup)")
            }

            let configuration: WorkerConfiguration
            do { configuration = try WorkerConfiguration.load(from: target.config) } catch {
                throw VMCommand.fail("cannot read the worker's configuration \(target.config): \(error)")
            }
            var settings = configuration.vm ?? VMSettings(storage: VMSettings.defaultStorage(home: target.home))
            if let storage { settings.storage = URL(fileURLWithPath: storage).standardizedFileURL.path }
            if let slots { settings.slots = slots }
            if let cpus { settings.cpus = cpus }
            if let memoryGb { settings.memoryGB = memoryGb }
            if let problem = settings.problem { throw VMCommand.fail(problem) }

            let xcode: VMSetupXcode?
            if let path = self.xcode {
                guard let (version, build) = try? VMImageBuilder.xcodeVersion(at: path) else {
                    throw VMCommand.fail("\(path) is not an Xcode")
                }
                xcode = VMSetupXcode(path: path, version: version, build: build)
            } else {
                xcode = VMSetupXcode.find()
            }
            let host = VMHost(settings: settings)
            let facts = VMSetupFacts(
                target: target, settings: settings, currentSettings: configuration.vm, xcode: xcode,
                licenseAccepted: xcode.map { Self.succeeds([$0.path + "/Contents/Developer/usr/bin/xcodebuild", "-license", "check"]) } ?? false,
                filterProblem: VMNetworkFilter.current().problem(installCommand: target.commands.asRoot("vm", "network", "install")),
                images: host.images().map(\.metadata),
                storageExists: FileManager.default.fileExists(atPath: settings.storage),
                volumeIgnoringOwnership: VMVolume.ownershipEnabled(at: settings.storage) ? nil : VMVolume.mountPoint(of: settings.storage))

            VMCommand.say("VM builds for the worker running as \(target.user) (\(target.binary))")
            VMCommand.say("")
            VMCommand.say("Checking this Mac:")
            let checks = await preflight(facts, configuration: configuration)
            for check in checks { VMCommand.say("  " + Self.line(check)) }
            if checks.contains(where: { $0.required && !$0.ok }) {
                throw VMCommand.fail("fix what is marked ✗, then run this again: \(target.commands.vmSetup)")
            }

            let steps = VMSetup.plan(facts)
            VMCommand.say("")
            if dryRun {
                VMCommand.say("The steps (dry run: nothing is changed):")
                for (index, step) in steps.enumerated() {
                    VMCommand.say("[\(index + 1)/\(steps.count)] \(step.title)\(step.done.map { ": \($0)" } ?? "")")
                    for action in step.actions { VMCommand.say("    " + Self.describe(action, target: target)) }
                }
                return
            }
            VMCommand.say("Setting up (about 15 minutes on a new Mac; Ctrl-C is safe, run it again to finish):")
            for (index, step) in steps.enumerated() {
                let counter = "[\(index + 1)/\(steps.count)]"
                if let done = step.done {
                    VMCommand.say("\(counter) ✓ \(step.title): \(done)")
                    continue
                }
                VMCommand.say("\(counter) \(step.title)\(step.estimate.map { " (\($0))" } ?? "")...")
                let started = ContinuousClock.now
                for action in step.actions {
                    do { try await perform(action, target: target) } catch {
                        throw VMCommand.fail("""
                            \(step.title) failed: \(error). Fix it and run this again; finished steps are skipped: \
                            \(target.commands.vmSetup)
                            """)
                    }
                }
                VMCommand.say("\(counter) ✓ \(step.title) (\(VMLauncherTiming.since(started)))")
            }

            let doctor = VMDoctor(host: host, identity: VMIdentityStore(dataDirectory: configuration.dataDirectory), commands: target.commands)
            let report = doctor.report(runningJobs: 0)
            VMCommand.say("")
            VMCommand.say("VM builds on this Mac:")
            for check in report.checks { VMCommand.say("  " + Self.line(check)) }
            VMCommand.say("")
            if report.problem == nil {
                VMCommand.say("""
                    Done. In Hangar › Machines this Mac shows its VM slots. If it says Builds Paused (a new Mac is \
                    enrolled paused until VM builds are ready), click Resume Builds. Archives sign with Hangar's \
                    certificate: create it once in Settings › Signing.
                    """)
            } else {
                throw VMCommand.fail("VM builds are not ready: \(report.problem!)")
            }
        }

        /// The administrator who ran sudo (or the current user, for a dry run without sudo).
        static func invoker(_ environment: [String: String]) -> (name: String, uid: UInt32, home: String)? {
            let name = environment["SUDO_USER"] ?? (geteuid() == 0 ? nil : NSUserName())
            let uid = environment["SUDO_UID"].flatMap(UInt32.init) ?? (geteuid() == 0 ? nil : getuid())
            guard let name, let uid, let home = FileManager.default.homeDirectory(forUser: name)?.path else { return nil }
            return (name, uid, home)
        }

        /// What must hold before anything changes, and what is only worth knowing.
        func preflight(_ facts: VMSetupFacts, configuration: WorkerConfiguration) async -> [VMCheck] {
            var checks: [VMCheck] = []
            #if arch(arm64)
            let appleSilicon = true
            #else
            let appleSilicon = false
            #endif
            checks.append(VMCheck(
                id: "chip", title: "Apple silicon", ok: appleSilicon,
                detail: appleSilicon ? "yes" : "macOS VMs need an Apple silicon Mac; this one builds on the host only"))
            let engine = LiveVirtualMachineEngine().unavailableReason()
            checks.append(VMCheck(id: "entitlement", title: "Virtualization", ok: engine == nil, detail: engine ?? "available"))

            let needsJobImage = facts.imageForXcode == nil
            let needsBase = needsJobImage && facts.newestBaseImage == nil
            if needsBase {
                let host = ProcessInfo.processInfo.operatingSystemVersion
                let hostVersion = "\(host.majorVersion).\(host.minorVersion).\(host.patchVersion)"
                let guest = VMSetup.defaultGuestMacOS
                let ok = hostVersion.compare(guest, options: .numeric) != .orderedAscending
                checks.append(VMCheck(
                    id: "macOS", title: "macOS", ok: ok,
                    detail: ok ? "\(hostVersion), runs the \(guest) image"
                        : "\(hostVersion) is older than the \(guest) image, which it cannot run: update macOS"))
            }

            if let xcode = facts.xcode {
                checks.append(VMCheck(id: "xcode", title: "Xcode", ok: true, detail: "\(xcode.version) (\(xcode.build)) at \(xcode.path)"))
                checks.append(VMCheck(
                    id: "license", title: "Xcode license", ok: facts.licenseAccepted, required: false,
                    detail: facts.licenseAccepted ? "accepted" : "not accepted yet; accepted below"))
            } else {
                checks.append(VMCheck(
                    id: "xcode", title: "Xcode", ok: !needsJobImage,
                    detail: needsJobImage
                        ? "none in /Applications: install it from the App Store, open it once, then run this again (or pass --xcode)"
                        : "none found, and none needed: the job image is here"))
            }

            let free = VMVolume.freeGB(at: facts.settings.storage)
            let need = VMSetup.requiredFreeGB(settings: facts.settings, needsBaseImage: needsBase, needsJobImage: needsJobImage)
            let freeText = String(format: "%.0f", free)
            checks.append(VMCheck(
                id: "disk", title: "Free space", ok: free >= Double(need),
                detail: free >= Double(need)
                    ? "\(freeText) GB free on the storage's volume, \(need) GB needed"
                    : "\(freeText) GB free on the storage's volume, but VM builds need \(need) GB (images, a saved state per slot, a job and the \(facts.settings.floorGB) GB floor). Free some space, or use an external APFS SSD: --storage /Volumes/<SSD>/hangar-vm"))

            let outcome = await WorkerCheck.run(configuration: configuration, transport: URLSessionTransport(), timeout: 10)
            switch outcome {
            case .accepted(let machine):
                checks.append(VMCheck(
                    id: "server", title: "Hangar", ok: true,
                    detail: "\(configuration.serverURL.absoluteString) knows this Mac as \(machine.name)\(machine.paused ? " (builds paused)" : "")"))
            case .unreachable:
                let tailscale = Self.tailscaleRunning()
                checks.append(VMCheck(
                    id: "server", title: "Hangar", ok: false, required: false,
                    detail: outcome.message(server: configuration.serverURL)
                        + (tailscale == false ? " Tailscale is not connected on this Mac: open it and log in." : " Check that this Mac is on the tailnet.")))
            default:
                checks.append(VMCheck(
                    id: "server", title: "Hangar", ok: false, required: false, detail: outcome.message(server: configuration.serverURL)))
            }
            return checks
        }

        func perform(_ action: VMSetupAction, target: VMSetupTarget) async throws {
            switch action {
            case .run(let arguments):
                let status = Self.run(arguments)
                guard status == 0 else { throw VMSetupFailure("\(arguments.joined(separator: " ")) exited with status \(status)") }
            case .installNetworkFilter:
                if let problem = try await VMCommand.installNetworkFilter(dryRun: false) { throw VMSetupFailure(problem) }
            case .restartWorker:
                if Self.run(["/bin/launchctl", "kill", "SIGTERM", target.launchdTarget]) != 0 {
                    // Not running (or not loaded yet): start it.
                    _ = Self.run(["/bin/launchctl", "kickstart", target.launchdTarget])
                }
            }
        }

        static func describe(_ action: VMSetupAction, target: VMSetupTarget) -> String {
            switch action {
            case .run(let arguments): arguments.map(GuestSSH.quote).joined(separator: " ")
            case .installNetworkFilter: target.commands.asRoot("vm", "network", "install")
            case .restartWorker: "/bin/launchctl kill SIGTERM \(target.launchdTarget)"
            }
        }

        static func line(_ check: VMCheck) -> String {
            let mark = check.ok ? "✓" : (check.required ? "✗" : "!")
            let fix = check.ok ? "" : check.command.map { " Run: \($0)" } ?? ""
            return "\(mark) \(check.title): \(check.detail)\(fix)"
        }

        /// Runs a command with this terminal's output; its exit status, or -1 when it cannot start.
        @discardableResult
        static func run(_ arguments: [String]) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: arguments[0])
            process.arguments = Array(arguments.dropFirst())
            do { try process.run() } catch { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }

        static func succeeds(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: arguments[0])
            process.arguments = Array(arguments.dropFirst())
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }

        /// Whether Tailscale says it is connected; nil when it is not installed where it usually is.
        static func tailscaleRunning() -> Bool? {
            let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
            guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
            return succeeds([binary, "status"])
        }
    }
}

struct VMSetupFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
