import ArgumentParser
import Foundation
import HangarClient
import HangarCore
import HangarMCP
import Synchronization

/// `hangar mcp`: a Model Context Protocol server on stdio for agents such as Claude Code. It calls the server's
/// public API with an API token (`APITokenSource`), so the server enforces the token's scope.
struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve Hangar's tools to an AI agent over MCP (stdio).",
        discussion: """
            Needs an API token: create one in the web UI under Settings › Agent Access, or with \
            `hangar tokens create <name> --scope deploy`. It is read from HANGAR_API_TOKEN, else from the file named \
            by HANGAR_API_TOKEN_FILE; never from an argument, and never from the CLI's own ~/.config/hangar/token. Keep it out of your \
            shell history: save it to its own file, and register the file's path with Claude Code:

              (umask 077; mkdir -p ~/.config/hangar; pbpaste > ~/.config/hangar/mcp-token)
              claude mcp add hangar --env HANGAR_SERVER=http://<server>:8787 \\
                --env HANGAR_API_TOKEN_FILE=$HOME/.config/hangar/mcp-token -- hangar mcp

            Owner tokens are refused: give an agent a read or deploy token.
            """)

    @Option(help: "The server's URL. Default: $HANGAR_SERVER, else http://localhost:8787.")
    var server: String?

    func validate() throws {
        if let server, URL(string: server)?.host() == nil {
            throw ValidationError("--server must be a URL such as http://mac-mini:8787")
        }
    }

    func run() async throws {
        let context = CLIContext.current
        let url = GlobalOptions.resolveServer(server, environment: context.environment)
        let token: String?
        do {
            token = try APITokenSource.resolve(
                environment: context.environment, includeDefaultFile: false, readFile: context.readFile)
        } catch {
            context.console.writeError("error: \(error.description)\n")
            throw ExitCode.failure
        }
        guard let token else {
            context.console.writeError(
                "error: set HANGAR_API_TOKEN_FILE to a file holding an API token (Settings › Agent Access in the web UI, or hangar tokens create).\n")
            throw ExitCode.failure
        }
        let api = context.makeAPI(url, token)
        // An owner token would hand the agent secrets and machines (security review M4). Unreachable server: the
        // tools report that themselves.
        if let current = try? await api.currentAPIToken(), current.scope == .owner {
            context.console.writeError(
                "error: '\(current.name)' is an owner token; give hangar mcp a read, deploy or configure token instead.\n")
            throw ExitCode.failure
        }
        let server = Self.server(api: api)
        let output = Mutex(())
        try await server.run(lines: FileHandle.standardInput.bytes.lines) { line in
            output.withLock { _ in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
        }
    }

    static func server(api: HangarAPI) -> MCPServer { HangarTools.server(api: api) }
}
