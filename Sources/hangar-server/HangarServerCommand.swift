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

            try FileManager.default.createDirectory(atPath: resolvedDirectory, withIntermediateDirectories: true)
            let database = try Database(path: resolvedDirectory + "/hangar.sqlite")
            try database.migrate()
            let configuration = ServerConfiguration(
                host: resolvedHost!, port: resolvedPort, dataDirectory: resolvedDirectory,
                retentionDays: retentionDays, minFreeDiskGB: minFreeDiskGb)
            let server = try HangarServerApp(
                configuration: configuration, database: database,
                appStoreConnectFactory: { LiveAppStoreConnectClient(credentials: $0, transport: URLSessionTransport()) })

            logger.info("data directory \(resolvedDirectory)")
            // runService() returns after SIGTERM/SIGINT; cancelling the group then stops the scheduler and sweeper.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { await server.scheduler.run() }
                group.addTask { await server.sweeper.run() }
                group.addTask { try await server.build().runService() }
                _ = try await group.next()
                group.cancelAll()
                while let _ = try await group.next() {}
            }
        }
    }
}
