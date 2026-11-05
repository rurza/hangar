import ArgumentParser
import Foundation
import HangarClient
import HangarCore

@main
struct Hangar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hangar",
        abstract: "Drive a Hangar build server: apps, variables, machines, deploys, builds and logs.",
        discussion: "The server is --server, else $HANGAR_SERVER, else http://localhost:8787.",
        subcommands: [
            Apps.self, Variables.self, Settings.self, Signing.self, Machines.self, Deploy.self, Status.self, Logs.self,
            Builds.self, Numbers.self, Cancel.self, Workflows.self, Tokens.self, MCP.self,
        ])
}

/// Options every command takes.
struct GlobalOptions: ParsableArguments {
    @Option(help: "The server's URL. Default: $HANGAR_SERVER, else http://localhost:8787.")
    var server: String?

    @Flag(help: "Print the server's JSON (pretty, sorted keys) and nothing else on stdout.")
    var json = false

    static func resolveServer(_ server: String?, environment: [String: String]) -> URL {
        let text = server ?? environment["HANGAR_SERVER"] ?? "http://localhost:8787"
        return URL(string: text) ?? URL(string: "http://localhost:8787")!
    }

    func validate() throws {
        if let server, URL(string: server)?.host() == nil {
            throw ValidationError("--server must be a URL such as http://mac-mini:8787")
        }
    }
}

/// A failure the CLI reports itself as `error: <message>`, exit code 1.
struct CLIError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Where output goes and input comes from; tests swap it to capture both.
struct Console: Sendable {
    var write: @Sendable (String) -> Void
    var writeError: @Sendable (String) -> Void
    var readInput: @Sendable () -> Data
    var isTTY: Bool

    static let live = Console(
        write: { FileHandle.standardOutput.write(Data($0.utf8)) },
        writeError: { FileHandle.standardError.write(Data($0.utf8)) },
        readInput: { FileHandle.standardInput.readDataToEndOfFile() },
        isTTY: isatty(STDOUT_FILENO) != 0)
}

/// The commands' dependencies, read from a task-local so tests can run a command with a `StubTransport`
/// and a capturing console (`CLIContext.$current.withValue(...)`) without any global mutable state.
/// The live value talks to the real server and the process's stdio.
struct CLIContext: Sendable {
    var makeAPI: @Sendable (URL) -> HangarAPI
    var console: Console
    var environment: [String: String]
    var timeZone: TimeZone
    /// How often a watch re-reads the build, besides following `/events`.
    var pollInterval: Duration
    /// How long a watch keeps retrying failed re-reads before it gives up with exit code 3.
    var lostContactAfter: Duration = .seconds(120)

    @TaskLocal static var current = CLIContext(
        makeAPI: { HangarAPI(baseURL: $0, transport: URLSessionTransport()) },
        console: .live, environment: ProcessInfo.processInfo.environment, timeZone: .current,
        pollInterval: .seconds(5))
}

/// What a command's body gets: the API for the chosen server and the output helpers.
struct CLI: Sendable {
    let api: HangarAPI
    let context: CLIContext
    let json: Bool

    var console: Console { context.console }
    var timeZone: TimeZone { context.timeZone }

    func print(_ text: String) { console.write(text + "\n") }
    func printError(_ text: String) { console.writeError(text + "\n") }

    /// Prints `value` as the server's JSON, pretty with sorted keys.
    func printJSON(_ value: some Encodable) throws { print(try Format.json(value)) }
}

/// A command that talks to the server. Its `run()` prints every failure as one `error: ...` line on stderr
/// (`error: <message> (<code>)` for a server error) and exits 1; `ExitCode` and `ValidationError` pass through.
protocol HangarCommand: AsyncParsableCommand {
    var global: GlobalOptions { get }
    func run(_ cli: CLI) async throws
}

extension HangarCommand {
    func run() async throws {
        let context = CLIContext.current
        let server = GlobalOptions.resolveServer(global.server, environment: context.environment)
        let cli = CLI(api: context.makeAPI(server), context: context, json: global.json)
        do {
            try await run(cli)
        } catch HangarAPIError.server(let error, _) {
            cli.printError("error: \(error.message) (\(error.code))")
            throw ExitCode.failure
        } catch HangarAPIError.transport(let error) {
            cli.printError("error: cannot reach the Hangar server at \(server.absoluteString): \(Format.describe(error))")
            throw ExitCode.failure
        } catch HangarAPIError.invalidResponse(let error) {
            cli.printError("error: the server at \(server.absoluteString) sent a response the CLI cannot read: \(error)")
            throw ExitCode.failure
        } catch let error as CLIError {
            cli.printError("error: \(error.message)")
            throw ExitCode.failure
        } catch let error as ExitCode {
            throw error
        } catch let error as ValidationError {
            throw error
        } catch {
            cli.printError("error: \(Format.describe(error))")
            throw ExitCode.failure
        }
    }
}

extension UUID: @retroactive ExpressibleByArgument {
    public init?(argument: String) { self.init(uuidString: argument) }
}
