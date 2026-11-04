import ArgumentParser
import Foundation
import HangarCore
import HangarWorker
import Logging

private let defaultSupportDirectory = NSHomeDirectory() + "/Library/Application Support/Hangar/worker"
private let defaultConfigPath = defaultSupportDirectory + "/config.json"

@main
struct HangarWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hangar-worker", abstract: "The Hangar build worker.",
        subcommands: [Run.self, Doctor.self, Setup.self])

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Runs the worker: heartbeats and builds assigned jobs.")

        @Option(help: "Worker configuration file.")
        var config: String = defaultConfigPath

        func run() async throws {
            LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }
            let logger = Logger(label: "app.hangar.worker")
            let configuration: WorkerConfiguration
            do {
                configuration = try WorkerConfiguration.load(from: config)
            } catch {
                throw ValidationError("\(error)")
            }
            let runner = LiveProcessRunner()
            let locator = XcodeLocator(runner: runner)
            let connection = HTTPServerConnection(baseURL: configuration.serverURL, token: configuration.token)
            let loop = WorkerLoop(
                configuration: configuration, connection: connection,
                doctor: HangarWorker.Doctor(
                    runner: runner, locator: locator, dataDirectory: configuration.dataDirectory),
                jobRunner: JobRunner(
                    connection: connection, runner: runner, locator: locator, dataDirectory: configuration.dataDirectory))
            logger.info("worker started", metadata: ["server": "\(configuration.serverURL)"])
            await loop.run()
        }
    }

    struct Doctor: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Prints this machine's health report as JSON.")

        func run() async throws {
            let runner = LiveProcessRunner()
            let doctor = HangarWorker.Doctor(runner: runner, locator: XcodeLocator(runner: runner))
            let encoder = JSONCoding.encoder
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(await doctor.report(runningJobIDs: []))
            print(String(decoding: data, as: UTF8.self))
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
        @Option(help: "Where the worker keeps checkouts and job files.")
        var dataDir: String = defaultSupportDirectory
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
            try WorkerConfiguration(serverURL: url, token: token, maxConcurrentJobs: maxJobs, dataDirectory: dataDir)
                .write(to: config)
            print("Wrote \(config)")
        }
    }
}
