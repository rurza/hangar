import ArgumentParser
import Foundation
import HangarCore
import HangarWorker
import Logging

/// `hangar-worker vm …`: VM builds (VM builds design). Image and slot commands run as the worker's user (`sudo -u
/// hangar -H hangar-worker vm …` on an isolated Mac): saved states are made and restored by the same user, and the
/// storage is that user's.
struct VMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vm", abstract: "Builds in a fresh macOS VM per job: storage, images, slots, network filter, signing.",
        subcommands: [
            Enable.self, Disable.self, Status.self, Image.self, Slots.self, Network.self, Identity.self, Smoke.self,
            RunJob.self,
        ])

    /// `--config` and `--storage`, shared by the commands that work on the VM storage.
    struct Location: ParsableArguments {
        @Option(help: "Worker configuration file; its `vm` section gives the storage and the VM's size.")
        var config: String = defaultConfigPath
        @Option(help: "VM storage directory (an APFS volume). Default: the configuration's, else ~/.hangar/vm.")
        var storage: String?

        /// The configuration's settings when it has a `vm` section, else the defaults; `--storage` wins.
        func settings() -> VMSettings {
            var settings = (try? WorkerConfiguration.load(from: config))?.vm ?? VMSettings()
            if let storage { settings.storage = URL(fileURLWithPath: storage).standardizedFileURL.path }
            return settings
        }

        func dataDirectory() -> String {
            (try? WorkerConfiguration.load(from: config))?.dataDirectory ?? defaultSupportDirectory
        }
    }

    static func say(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

    static func fail(_ message: String) -> ExitCode {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return ExitCode(1)
    }

    // MARK: enable / disable / status

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turns VM builds on for this worker: every job then runs in a VM, none on the host.",
            discussion: "Restart the worker afterwards. Until an image, the network filter and the slot states are ready, the Mac takes no jobs.")

        @Option(help: "Worker configuration file.")
        var config: String = defaultConfigPath
        @Option(help: "VM storage directory on an APFS volume (an external SSD works). Default: ~/.hangar/vm.")
        var storage: String?
        @Option(help: "VMs at once (1 or 2).")
        var slots: Int?
        @Option(help: "Virtual CPUs per VM.")
        var cpus: Int?
        @Option(help: "Memory per VM in GB.")
        var memoryGb: Int?
        @Option(help: "Stop a job that runs longer than this, with its VM.")
        var timeoutMinutes: Int?
        @Option(help: "Free space, in GB, to leave on the storage volume beyond each job's reserve.")
        var floorGb: Int?

        func run() async throws {
            var configuration: WorkerConfiguration
            do { configuration = try WorkerConfiguration.load(from: config) } catch { throw VMCommand.fail("\(error)") }
            var settings = configuration.vm ?? VMSettings()
            if let storage { settings.storage = URL(fileURLWithPath: storage).standardizedFileURL.path }
            if let slots { settings.slots = slots }
            if let cpus { settings.cpus = cpus }
            if let memoryGb { settings.memoryGB = memoryGb }
            if let timeoutMinutes { settings.jobTimeoutMinutes = timeoutMinutes }
            if let floorGb { settings.floorGB = floorGb }
            if let problem = settings.problem { throw VMCommand.fail(problem) }
            try VMStorage(root: settings.storage).create()
            if let problem = VMVolume.problem(at: settings.storage) { VMCommand.say("warning: \(problem)") }
            configuration.vm = settings
            try configuration.write(to: config)
            VMCommand.say("VM builds on: storage \(settings.storage), \(settings.slots) slot(s) of \(settings.cpus) CPUs and \(settings.memoryGB) GB. Restart the worker.")
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turns VM builds off: jobs build on the host again. Images and states stay on disk.")

        @Option(help: "Worker configuration file.")
        var config: String = defaultConfigPath

        func run() async throws {
            var configuration: WorkerConfiguration
            do { configuration = try WorkerConfiguration.load(from: config) } catch { throw VMCommand.fail("\(error)") }
            configuration.vm = nil
            try configuration.write(to: config)
            VMCommand.say("VM builds off. Restart the worker.")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Prints what VM builds on this Mac have and lack, as JSON.")

        @OptionGroup var location: Location

        func run() async throws {
            let settings = location.settings()
            let doctor = VMDoctor(host: VMHost(settings: settings), identity: VMIdentityStore(dataDirectory: location.dataDirectory()))
            let encoder = JSONCoding.encoder
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(doctor.report(runningJobs: 0))
            print(String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: image

    struct Image: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Imports, builds, lists and removes VM images.", subcommands: [Import.self, Build.self, List.self, Remove.self])

        struct Import: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Pulls a Tart-format macOS image, pinned by digest (about 25 GB, 5 minutes).",
                discussion: "Default: \(VMImageImporter.defaultVanilla). It stops, and leaves nothing behind, when free space would fall below the floor.")

            @Argument(help: "registry/repository:tag@sha256:digest")
            var reference: String = VMImageImporter.defaultVanilla
            @Option(help: "The image's name. Default: vanilla-<tag>.")
            var name: String?
            @OptionGroup var location: Location

            func run() async throws {
                guard let parsed = OCIReference(reference) else { throw VMCommand.fail("\(reference) is not registry/repository:tag@sha256:digest") }
                let name = name ?? "vanilla-" + (parsed.tag ?? "image")
                guard VMStorage.isValidImageName(name) else { throw VMCommand.fail("\(name) is not a valid image name") }
                let settings = location.settings()
                let importer = VMImageImporter(floorGB: settings.floorGB, progress: VMCommand.say)
                do {
                    try await importer.importImage(parsed, as: name, into: VMStorage(root: settings.storage))
                } catch {
                    throw VMCommand.fail("\(error)")
                }
                VMCommand.say("imported \(name)")
            }
        }

        struct Build: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Builds a job image from a vanilla one: the build user, Homebrew, this Mac's Xcode, then the slot states.",
                discussion: """
                    Over SSH as the vanilla image's admin: replaces admin's published password, creates the standard \
                    user builder (no sudo) that owns /opt/homebrew with Homebrew in it, streams this Mac's Xcode in, \
                    runs xcodebuild -runFirstLaunch, downloads the simulator platforms asked for, turns off Spotlight, \
                    sleep and software update, and turns on automatic login for builder. Then it saves a state per slot.
                    """)

            @Option(help: "The vanilla image to start from.")
            var from: String = "vanilla-26.6.2"
            @Option(help: "The Xcode to copy in. Default: /Applications/Xcode.app.")
            var xcode: String = "/Applications/Xcode.app"
            @Option(help: "The image's name. Default: xcode-<version>.")
            var name: String?
            @Option(name: .customLong("platform"), help: "A simulator platform to download in the guest (iOS, watchOS…); repeatable. Default: iOS.")
            var platforms: [String] = []
            @Flag(help: "Download no simulator platform (archives only; saves 8 to 17 GB).")
            var noPlatforms = false
            @Flag(help: "Skip the Metal toolchain download (about 3 GB; only projects with Metal shaders need it).")
            var noMetalToolchain = false
            @Flag(help: "Leave the slot states for later (`vm slots prepare`).")
            var skipSlots = false
            @OptionGroup var location: Location

            func run() async throws {
                let settings = location.settings()
                let host = VMHost(settings: settings)
                let builder = VMImageBuilder(host: host, progress: VMCommand.say)
                let image: VMImage
                do {
                    image = try await builder.build(
                        from: from, xcodePath: xcode, name: name, platforms: noPlatforms ? [] : (platforms.isEmpty ? ["iOS"] : platforms),
                        metalToolchain: !noMetalToolchain)
                } catch {
                    throw VMCommand.fail("\(error)")
                }
                VMCommand.say("built \(image.metadata.name): Xcode \(image.metadata.xcode ?? "?"), \(image.metadata.simulatorRuntimes.joined(separator: ", "))")
                guard !skipSlots else { return }
                for slot in 0..<settings.slots {
                    do { try await VMLauncher(host: host).prepareSlot(image: image, slot: slot, progress: VMCommand.say) } catch {
                        throw VMCommand.fail("slot \(slot): \(error)")
                    }
                }
            }
        }

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Lists the images and their slots.")

            @OptionGroup var location: Location

            func run() async throws {
                let host = VMHost(settings: location.settings())
                let images = host.images()
                if images.isEmpty { VMCommand.say("no images in \(host.storage.images)") }
                for image in images {
                    let kind = image.metadata.isJobImage ? "Xcode \(image.metadata.xcode ?? "?")" : "base image"
                    VMCommand.say("\(image.metadata.name): \(kind), macOS \(image.metadata.macOS), from \(image.metadata.source)")
                    for slot in 0..<host.settings.slots {
                        VMCommand.say("  slot \(slot): \(VMDoctor.slotState(image: image, slot: slot, host: host))")
                    }
                }
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Deletes an image and its slot states.")

            @Argument var name: String
            @OptionGroup var location: Location

            func run() async throws {
                guard VMStorage.isValidImageName(name) else { throw VMCommand.fail("\(name) is not a valid image name") }
                let storage = VMStorage(root: location.settings().storage)
                let path = storage.image(name).path
                guard FileManager.default.fileExists(atPath: path) else { throw VMCommand.fail("no image \(name)") }
                try FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: storage.partialImage(name).path)
                VMCommand.say("removed \(name)")
            }
        }
    }

    // MARK: slots

    struct Slots: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Saves the slot states of an image again.", subcommands: [Prepare.self])

        struct Prepare: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Boots each slot's clone, waits for it to settle and saves its state (about a minute a slot).",
                discussion: "Stop the worker first: a slot in use by a job cannot be saved.")

            @Option(help: "The image. Default: every job image.")
            var image: String?
            @OptionGroup var location: Location

            func run() async throws {
                let host = VMHost(settings: location.settings())
                let images = host.images().filter { image == nil ? $0.metadata.isJobImage : $0.metadata.name == image }
                guard !images.isEmpty else { throw VMCommand.fail("no such image") }
                for image in images {
                    for slot in 0..<host.settings.slots {
                        do { try await VMLauncher(host: host).prepareSlot(image: image, slot: slot, progress: VMCommand.say) } catch {
                            throw VMCommand.fail("\(image.metadata.name) slot \(slot): \(error)")
                        }
                    }
                }
            }
        }
    }

    // MARK: network

    struct Network: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "The pf rules that keep VMs off this Mac, the LAN and the tailnet.",
            subcommands: [Install.self, Uninstall.self, Rules.self, Check.self])

        struct Install: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Installs the network filter as a LaunchDaemon (needs sudo; run it as an administrator).",
                discussion: "Writes \(VMNetworkFilter.rulesPath), \(VMNetworkFilter.loaderPath) and \(VMNetworkFilter.daemonPath), and loads the anchor \(VMNetworkFilter.anchor). /etc/pf.conf is not changed. Running it again replaces them.")

            @Flag(help: "Print the files and the sudo commands instead of running them.")
            var dryRun = false

            func run() async throws {
                let filter = VMNetworkFilter.current()
                let staging = NSTemporaryDirectory() + "hangar-pf-" + UUID().uuidString
                try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(atPath: staging) }
                try filter.rules.write(toFile: staging + "/rules", atomically: true, encoding: .utf8)
                try VMNetworkFilter.loaderScript.write(toFile: staging + "/loader.sh", atomically: true, encoding: .utf8)
                try VMNetworkFilter.daemonPlist.write(toFile: staging + "/daemon.plist", atomically: true, encoding: .utf8)
                let commands = filter.installCommands(staging: staging)
                if dryRun {
                    VMCommand.say("# \(VMNetworkFilter.rulesPath)\n\(filter.rules)")
                    VMCommand.say("# \(VMNetworkFilter.loaderPath)\n\(VMNetworkFilter.loaderScript)")
                    VMCommand.say("# \(VMNetworkFilter.daemonPath)\n\(VMNetworkFilter.daemonPlist)")
                    VMCommand.say("# commands (each with sudo):")
                    for command in commands { VMCommand.say("sudo " + command.map(GuestSSH.quote).joined(separator: " ")) }
                    return
                }
                try VMCommand.sudo(commands, tolerateFailure: { $0.contains("bootout") })
                VMCommand.say(filter.problem().map { "warning: \($0)" } ?? "the VM network filter is loaded")
            }
        }

        struct Uninstall: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Removes the network filter (needs sudo). VM builds then stop.")

            @Flag(help: "Print the sudo commands instead of running them.")
            var dryRun = false

            func run() async throws {
                if dryRun {
                    for command in VMNetworkFilter.uninstallCommands { VMCommand.say("sudo " + command.map(GuestSSH.quote).joined(separator: " ")) }
                    return
                }
                try VMCommand.sudo(VMNetworkFilter.uninstallCommands, tolerateFailure: { _ in true })
            }
        }

        struct Rules: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Prints the pf rules for this Mac's VM subnet.")
            func run() async throws { print(VMNetworkFilter.current().rules, terminator: "") }
        }

        struct Check: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Says whether the worker sees the filter as loaded.")
            func run() async throws {
                if let problem = VMNetworkFilter.current().problem() { throw VMCommand.fail(problem) }
                VMCommand.say("the VM network filter is loaded")
            }
        }
    }

    /// Runs each command with sudo in the terminal; sudo asks for the password once.
    static func sudo(_ commands: [[String]], tolerateFailure: ([String]) -> Bool) throws {
        for command in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = command
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0, !tolerateFailure(command) {
                throw fail("sudo \(command.joined(separator: " ")) exited with status \(process.terminationStatus)")
            }
        }
    }

    // MARK: identity

    struct Identity: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "The worker's one Apple Development identity, injected into each job's VM.",
            subcommands: [Import.self, FromKeychain.self, Show.self, Remove.self])

        struct Import: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Stores a .p12 (an Apple Development certificate with its key) for VM jobs.",
                discussion: "The password comes from HANGAR_P12_PASSWORD, or is asked for. The file and its password are kept 0600 next to the worker's configuration.")

            @Argument var file: String
            @Option(help: "Worker configuration file.")
            var config: String = defaultConfigPath

            func run() async throws {
                guard let data = FileManager.default.contents(atPath: file) else { throw VMCommand.fail("cannot read \(file)") }
                let password = ProcessInfo.processInfo.environment["HANGAR_P12_PASSWORD"]
                    ?? String(cString: getpass("Password for \((file as NSString).lastPathComponent): "))
                let directory = (try? WorkerConfiguration.load(from: config))?.dataDirectory ?? defaultSupportDirectory
                try VMIdentityStore(dataDirectory: directory).save(p12: data, password: SensitiveText(password))
                VMCommand.say("stored the VM signing identity in \(directory)")
            }
        }

        struct FromKeychain: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "from-keychain",
                abstract: "Exports the CI keychain's identities (the one the host's archives created) for VM jobs.")

            @Option(help: "Worker configuration file.")
            var config: String = defaultConfigPath

            func run() async throws {
                guard let keychain = CIKeychain.installed() else { throw VMCommand.fail("this user has no CI keychain (run hangar-worker isolate)") }
                let directory = (try? WorkerConfiguration.load(from: config))?.dataDirectory ?? defaultSupportDirectory
                do {
                    try await VMIdentityStore(dataDirectory: directory).exportFromKeychain(keychain, runner: LiveProcessRunner())
                } catch {
                    throw VMCommand.fail("\(error)")
                }
                VMCommand.say("stored the VM signing identity in \(directory)")
            }
        }

        struct Show: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "status", abstract: "Says whether an identity is stored.")

            @Option(help: "Worker configuration file.")
            var config: String = defaultConfigPath

            func run() async throws {
                let directory = (try? WorkerConfiguration.load(from: config))?.dataDirectory ?? defaultSupportDirectory
                let store = VMIdentityStore(dataDirectory: directory)
                VMCommand.say(store.exists ? "stored: \(store.file)" : "none: archives in VMs fail until one is imported")
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Deletes the stored identity.")

            @Option(help: "Worker configuration file.")
            var config: String = defaultConfigPath

            func run() async throws {
                let directory = (try? WorkerConfiguration.load(from: config))?.dataDirectory ?? defaultSupportDirectory
                VMIdentityStore(dataDirectory: directory).remove()
                VMCommand.say("removed")
            }
        }
    }

    // MARK: smoke

    struct Smoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Boots a job's VM from an image's slot as a job would, runs a command in it, and deletes it.",
            discussion: "Prints how the VM came up. Stop the worker first, or pick a slot no job uses.")

        @Option(help: "The image. Default: the first one.")
        var image: String?
        @Option(help: "The slot to restore.")
        var slot: Int = 0
        @Option(help: "The guest user. Default: the image's build user, else admin.")
        var user: String?
        @Option(help: "The command to run in the guest.")
        var command: String = "sw_vers; id; uptime"
        @OptionGroup var location: Location

        func run() async throws {
            let host = VMHost(settings: location.settings())
            guard let chosen = host.images().first(where: { image == nil || $0.metadata.name == image }) else {
                throw VMCommand.fail("no such image in \(host.storage.images)")
            }
            if let reason = host.engine.unavailableReason() { throw VMCommand.fail(reason) }
            let job = host.storage.job(UUID())
            try host.storage.create()
            defer { try? SafeRemoval.removeItem(atPath: job.path, within: host.storage.jobs) }
            let user = user ?? chosen.metadata.buildUser ?? "admin"
            let started = ContinuousClock.now
            let vm: RunningVM
            do { vm = try await VMLauncher(host: host).bootJob(image: chosen, slot: slot, job: job, user: user) } catch {
                throw VMCommand.fail("\(error)")
            }
            VMCommand.say("VM up at \(vm.address): \(vm.note); \(VMLauncherTiming.since(started)) from start")
            let outcome = try await host.ssh(for: chosen.directory).run(user: user, host: vm.address, command, onLine: VMCommand.say)
            await vm.machine.stop()
            VMCommand.say("command exited \(outcome.exitCode); VM stopped and its clone deleted")
            if vm.slotIsStale { VMCommand.say("slot \(slot) has no usable state: run `hangar-worker vm slots prepare`") }
        }
    }

    // MARK: run-job (in the guest)

    struct RunJob: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run-job", abstract: "In a job's VM: runs the job the host sends on standard input.",
            shouldDisplay: false)

        func run() async throws {
            LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }
            WorkerPrivacy.standardUmask()
            let control = GuestControlReader()
            let bundle: GuestJobBundle
            do { bundle = try control.readBundle() } catch { throw VMCommand.fail("\(error)") }
            let result = await GuestJobRunner().run(
                bundle, cancelled: { control.isCancelled }, stopReason: { control.stopReason })
            print(GuestJobRunner.resultLine(result))
        }
    }
}

enum VMLauncherTiming {
    static func since(_ start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return String(format: "%.1f s", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
}
