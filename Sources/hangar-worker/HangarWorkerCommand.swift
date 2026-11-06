import ArgumentParser
import Foundation
import HangarCore
import HangarWorker
import Logging

let defaultSupportDirectory = NSHomeDirectory() + "/Library/Application Support/Hangar/worker"
let defaultConfigPath = defaultSupportDirectory + "/config.json"

@main
struct HangarWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hangar-worker", abstract: "The Hangar build worker.",
        subcommands: [Run.self, Doctor.self, Setup.self, Check.self, Isolate.self, VMCommand.self])

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Runs the worker: heartbeats and builds assigned jobs.")

        @Option(help: "Worker configuration file.")
        var config: String = defaultConfigPath

        func run() async throws {
            LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }
            let logger = Logger(label: "app.hangar.worker")
            // Everything the worker and its jobs create is private to this user (worker isolation design).
            WorkerPrivacy.standardUmask()
            let user = NSUserName()
            let home = NSHomeDirectory()
            if WorkerPrivacy.isDedicatedAccount(user: user, home: home) {
                do { try WorkerPrivacy.lockDown(home: home) } catch {
                    logger.warning("could not set \(home) to mode 0700: \(error)")
                }
            }
            let configuration: WorkerConfiguration
            do {
                configuration = try WorkerConfiguration.load(from: config)
            } catch {
                throw ValidationError("\(error)")
            }
            if let warning = WorkerPrivacy.startupWarning(user: user, home: home, vmBuilds: configuration.vm != nil) {
                logger.warning("\(warning)")
            }
            let runner = LiveProcessRunner()
            let locator = XcodeLocator(runner: runner)
            let connection = HTTPServerConnection(baseURL: configuration.serverURL, token: configuration.token)
            let work = configuration.resolvedWorkDirectory
            // Headless (the hangar user's LaunchDaemon, set up by isolate): signs with its own CI keychain.
            let keychain = CIKeychain.installed()
            var loopConfiguration = configuration
            var vmDoctor: VMDoctor?
            let jobRunner: any JobRunning
            if let settings = configuration.vm {
                // VM builds: every job in a fresh VM, as many at once as there are slots.
                let host = VMHost(settings: settings, runner: runner)
                for line in VMMaintenance.sweep(storage: host.storage) { logger.info("\(line)") }
                do { try await GuestKeys.ensure(storage: host.storage, runner: runner) } catch {
                    logger.error("could not create the key for VM guests: \(error)")
                }
                let identity = VMIdentityStore(dataDirectory: configuration.dataDirectory)
                let doctor = VMDoctor(host: host, identity: identity)
                let pool = VMSlotPool(count: settings.slots)
                vmDoctor = doctor
                loopConfiguration.maxConcurrentJobs = settings.slots
                jobRunner = VMJobRunner(
                    host: host, connection: connection, serverURL: configuration.serverURL, identity: identity, slots: pool,
                    workerBinary: Bundle.main.executablePath ?? CommandLine.arguments[0],
                    readiness: { doctor.readinessProblem() })
                if doctor.readinessProblem() == nil {
                    Task { await VMMaintenance.prepareSlots(host: host, pool: pool) { logger.info("\($0)") } }
                }
                logger.info("VM builds on", metadata: [
                    "storage": "\(settings.storage)", "slots": "\(settings.slots)",
                    "ready": "\(doctor.readinessProblem() ?? "yes")",
                ])
            } else {
                jobRunner = JobRunner(
                    connection: connection, runner: runner, locator: locator, dataDirectory: work, keychain: keychain)
            }
            let loop = WorkerLoop(
                configuration: loopConfiguration, connection: connection,
                doctor: HangarWorker.Doctor(
                    runner: runner, locator: locator, dataDirectory: work, keychain: keychain, vm: vmDoctor),
                jobRunner: jobRunner)
            logger.info("worker started", metadata: [
                "server": "\(configuration.serverURL)", "version": "\(JobRunner.workerVersion)", "work": "\(work)",
                "keychain": "\(keychain?.path ?? "login")",
            ])
            let signals = Self.stopOnSignals(loop)
            await loop.run()
            signals.forEach { $0.cancel() }
            logger.info("worker stopped")
        }

        /// SIGTERM (launchd stopping the agent, `launchctl bootout`, an update) and SIGINT stop the worker
        /// gracefully: running jobs are cancelled with the reason, report it and clean up before the process exits.
        /// launchd sends SIGKILL if that takes longer than its exit timeout (20 s by default).
        static func stopOnSignals(_ loop: WorkerLoop) -> [any DispatchSourceSignal] {
            [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")].map { number, name in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler {
                    Task { await loop.stop(reason: "hangar-worker on \(JobRunner.computerName) was stopped (\(name))") }
                }
                source.resume()
                return source
            }
        }
    }

    struct Doctor: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Prints this machine's health report as JSON.")

        @Option(help: "Worker configuration file; with VM builds on, the report has a vm section.")
        var config: String = defaultConfigPath

        func run() async throws {
            let runner = LiveProcessRunner()
            let configuration = try? WorkerConfiguration.load(from: config)
            let vm = configuration?.vm.map { settings in
                VMDoctor(
                    host: VMHost(settings: settings, runner: runner),
                    identity: VMIdentityStore(dataDirectory: configuration!.dataDirectory))
            }
            let doctor = HangarWorker.Doctor(
                runner: runner, locator: XcodeLocator(runner: runner), keychain: CIKeychain.installed(), vm: vm)
            let encoder = JSONCoding.encoder
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(await doctor.report(runningJobIDs: []))
            print(String(decoding: data, as: UTF8.self))
        }
    }

    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Checks that the server still accepts this machine's token.",
            discussion: """
                Prints the machine's name on standard output and a message on standard error. Exit status: 0 the \
                token is accepted, 3 the server refuses it (the machine was removed in Hangar), 4 the server cannot \
                be reached, 2 the configuration cannot be read, 1 anything else. Nothing secret is printed.
                """)

        @Option(help: "Worker configuration file.")
        var config: String = defaultConfigPath

        func run() async throws {
            let configuration: WorkerConfiguration
            do {
                configuration = try WorkerConfiguration.load(from: config)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                throw ExitCode(2)
            }
            let outcome = await WorkerCheck.run(configuration: configuration, transport: URLSessionTransport())
            FileHandle.standardError.write(Data((outcome.message(server: configuration.serverURL) + "\n").utf8))
            if case .accepted(let machine) = outcome { print(machine.name) }
            if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
        }
    }

    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Writes the worker configuration (mode 0600).",
            discussion: "The token may come from HANGAR_WORKER_TOKEN instead of --token, which keeps it out of the process list.")

        @Option(help: "The Hangar server's URL, such as http://mac-mini:8787.")
        var server: String
        @Option(help: "The machine's token from `hangar machines add`. Default: $HANGAR_WORKER_TOKEN.")
        var token: String?
        @Option(help: "Where the worker keeps its state.")
        var dataDir: String = defaultSupportDirectory
        @Option(help: "Where checkouts, DerivedData and job files go; no spaces. Default: the data directory when its path has no spaces, else ~/.hangar/<name>.")
        var workDir: String?
        @Option(help: "Jobs to run at once.")
        var maxJobs: Int = 1
        @Option(help: "Configuration file to write.")
        var config: String = defaultConfigPath

        func run() async throws {
            guard let url = URL(string: server), let scheme = url.scheme, ["http", "https"].contains(scheme),
                url.host != nil
            else { throw ValidationError("--server must be an http(s) URL") }
            guard let token = token ?? ProcessInfo.processInfo.environment["HANGAR_WORKER_TOKEN"], !token.isEmpty else {
                throw ValidationError("pass --token or set HANGAR_WORKER_TOKEN")
            }
            guard maxJobs >= 1 else { throw ValidationError("--max-jobs must be at least 1") }
            if let workDir, workDir.contains(where: \.isWhitespace) {
                throw ValidationError("--work-dir must not contain spaces: scripts written for Xcode Cloud assume none")
            }
            // An existing configuration keeps its work directory when none is given.
            let existing = try? WorkerConfiguration.load(from: config)
            try WorkerConfiguration(
                serverURL: url, token: token, maxConcurrentJobs: maxJobs, dataDirectory: dataDir,
                workDirectory: workDir ?? existing?.workDirectory
            ).write(to: config)
            print("Wrote \(config)")
        }
    }

    struct Isolate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Moves this Mac's worker onto the dedicated, unprivileged hangar user.",
            discussion: """
                Run it in Terminal as an administrator, without sudo; it asks for your password when it needs sudo. \
                It creates the hangar user with a generated password (shown once and saved in your login keychain \
                as app.hangar.worker-account; nobody logs in as hangar, so it is only for emergencies), copies the \
                worker, its configuration (the same machine token) and its build cache into that user, locks the \
                user's home to 0700, creates hangar's CI keychain (its password in a 0600 file in that home) and \
                installs the worker as a LaunchDaemon that runs as hangar from boot, with no login. It confirms the \
                worker runs and reaches the server as hangar, then removes this user's agent and configuration. A \
                hangar user set up by an older version (a launch agent and a login) is moved to the LaunchDaemon. \
                Running it again picks up where it stopped.
                """)

        @Flag(help: "Print the steps instead of doing them. Nothing runs with sudo.")
        var dryRun = false
        @Option(help: "The worker configuration to move. Default: this user's worker configuration.")
        var config: String?
        @Option(help: "The hangar-worker binary to install for hangar. Default: this executable.")
        var binary: String?
        @Option(help: "The Hangar server's data directory on this Mac, checked to be unreadable by hangar; empty skips it. Default: this user's, when it exists.")
        var serverData: String?
        @Flag(help: "Give an existing hangar user a new generated password.")
        var resetPassword = false

        func run() async throws {
            let probe = TerminalRunner()
            let groups = (try? probe.run(.probe("/usr/bin/id", "-Gn")))?.output.split(separator: " ") ?? []
            let invoker = IsolationInvoker(
                name: NSUserName(), uid: getuid(), home: NSHomeDirectory(), isAdmin: groups.contains("admin"))
            let staging = NSTemporaryDirectory() + "hangar-isolate-" + UUID().uuidString
            defer { try? FileManager.default.removeItem(atPath: staging) }
            let say: @Sendable (String) -> Void = { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
            let isolation = WorkerIsolation(
                invoker: invoker,
                options: IsolationOptions(
                    dryRun: dryRun, sourceConfig: config, binary: binary, serverData: serverData,
                    resetPassword: resetPassword),
                dependencies: .init(
                    runner: dryRun ? DryRunRunner(print: say) : TerminalRunner(),
                    passwords: LoginKeychainPasswordStore(), verifier: OpenDirectoryPasswordVerifier(),
                    generator: RandomPasswordGenerator(),
                    check: { await WorkerCheck.run(configuration: $0, transport: URLSessionTransport()) },
                    sleep: { try? await Task.sleep(for: $0) }, now: Date.init, say: say,
                    stagingDirectory: staging, ownExecutable: Bundle.main.executablePath))
            do {
                _ = try await isolation.run()
            } catch let error as IsolationError {
                FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
                throw ExitCode(1)
            }
        }
    }
}
