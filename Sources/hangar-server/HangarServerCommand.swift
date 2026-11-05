import ArgumentParser
import Foundation
import HangarAppStoreConnect
import HangarCore
import HangarServer
import Hummingbird
import Logging

@main
struct HangarServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hangar-server", abstract: "The Hangar build server.", subcommands: [Run.self])

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Runs the server. Precedence: flag, then HANGAR_HOST / HANGAR_PORT / HANGAR_DATA_DIR, then default.")

        @Option(help: "Address to bind. Default: this Mac's Tailscale IPv4 (waits up to 60 s for it).")
        var host: String?
        @Option(help: "Port to listen on. Default: 8787.")
        var port: Int?
        @Option(help: "Directory for hangar.sqlite, master.key and jobs/. Default: ~/Library/Application Support/Hangar/server.")
        var dataDir: String?
        @Option(help: "Delete job logs and artifacts of builds finished longer ago than this.")
        var retentionDays: Int = 30
        @Option(help: "Machines with less free disk get no new jobs.")
        var minFreeDiskGb: Double = 20
        @Option(
            name: .customLong("allowed-host"),
            help: ArgumentHelp(
                "Another host name the server answers to (repeatable); HANGAR_ALLOWED_HOSTS takes a comma-separated list.",
                discussion: "Always allowed: the bound address, localhost when bound to loopback, this Mac's host name, its MagicDNS name and any *.ts.net name."))
        var allowedHosts: [String] = []

        func run() async throws {
            LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }
            let logger = Logger(label: "app.hangar.server")
            let environment = ProcessInfo.processInfo.environment

            let resolvedPort = try port ?? environment["HANGAR_PORT"].map { value in
                guard let parsed = Int(value), (1...65535).contains(parsed) else {
                    throw ValidationError("HANGAR_PORT must be a port number")
                }
                return parsed
            } ?? 8787
            let resolvedDirectory = dataDir ?? environment["HANGAR_DATA_DIR"]
                ?? NSHomeDirectory() + "/Library/Application Support/Hangar/server"
            var resolvedHost = host ?? environment["HANGAR_HOST"]
            if resolvedHost == nil {
                // No loopback fallback: it would stick after a login-time race. Exit so launchd KeepAlive retries.
                resolvedHost = await TailscaleAddress.waitForAddress(runner: LiveProcessRunner())
                guard resolvedHost != nil else {
                    FileHandle.standardError.write(
                        Data("Tailscale address not found; start Tailscale or pass --host <address>\n".utf8))
                    throw ExitCode.failure
                }
            }

            try ServerConfiguration.prepareDataDirectory(at: resolvedDirectory)
            let database = try Database(path: resolvedDirectory + "/hangar.sqlite")
            try database.migrate()
            let extraHosts = allowedHosts
                + (environment["HANGAR_ALLOWED_HOSTS"] ?? "").split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            let localNames = await HostPolicy.detectLocalNames(runner: LiveProcessRunner())
            let configuration = ServerConfiguration(
                host: resolvedHost!, port: resolvedPort, dataDirectory: resolvedDirectory,
                retentionDays: retentionDays, minFreeDiskGB: minFreeDiskGb, allowedHosts: localNames + extraHosts,
                workerBinaryPath: WorkerBinary.locate())
            let server = try HangarServerApp(
                configuration: configuration, database: database,
                appStoreConnectFactory: { LiveAppStoreConnectClient(credentials: $0, transport: URLSessionTransport()) })

            try server.backfillAppIcons()

            logger.info("data directory \(resolvedDirectory)")
            logger.info("allowed host names: \(configuration.hostPolicy.description)")
            if let worker = configuration.workerBinaryPath {
                logger.info("one-command worker install: serving \(worker) at /install")
            } else {
                logger.warning(
                    "one-command worker install unavailable: no hangar-worker next to hangar-server; reinstall with scripts/server/install-server.sh")
            }
            logger.info("Hangar is running at \(Self.webURL(host: configuration.host, port: configuration.port))")
            // The service group returns after SIGTERM/SIGINT (open event streams end at once; anything else gets 5 s);
            // cancelling the task group then stops the scheduler and sweeper.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { await server.scheduler.run() }
                group.addTask { await server.sweeper.run() }
                group.addTask { try await server.serviceGroup(running: server.build(), logger: logger).run() }
                _ = try await group.next()
                group.cancelAll()
                while let _ = try await group.next() {}
            }
        }

        /// The web app's address; an IPv6 host goes in brackets.
        static func webURL(host: String, port: Int) -> String {
            "http://\(host.contains(":") ? "[\(host)]" : host):\(port)/"
        }
    }
}
