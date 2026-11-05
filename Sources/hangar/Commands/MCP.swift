import ArgumentParser
import Foundation
import HangarClient
import HangarCore
import HangarMCP
import Synchronization

/// `hangar mcp`: a Model Context Protocol server on stdio for agents such as Claude Code. It calls the server's
/// public API with the API token in `HANGAR_API_TOKEN`, so the server enforces the token's scope.
struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve Hangar's tools to an AI agent over MCP (stdio).",
        discussion: """
            Needs HANGAR_API_TOKEN: create one in the web UI under Settings › Agent Access, or with \
            `hangar tokens create <name> --scope deploy`. The token is read from the environment only, never from \
            an argument, and is sent only to the server. Register it with Claude Code:

              claude mcp add hangar --env HANGAR_SERVER=http://<server>:8787 --env HANGAR_API_TOKEN=hgr_... -- hangar mcp
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
        guard let token = context.environment["HANGAR_API_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            context.console.writeError(
                "error: set HANGAR_API_TOKEN to an API token (Settings › Agent Access in the web UI, or hangar tokens create).\n")
            throw ExitCode.failure
        }
        guard APIToken.isWellFormedSecret(token) else {
            context.console.writeError("error: HANGAR_API_TOKEN is not a Hangar API token (they start with hgr_).\n")
            throw ExitCode.failure
        }
        let api = HangarAPI(baseURL: url, transport: URLSessionTransport(), token: token)
        let server = Self.server(api: api)
        let output = Mutex(())
        try await server.run(lines: FileHandle.standardInput.bytes.lines) { line in
            output.withLock { _ in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
        }
    }

    static func server(api: HangarAPI) -> MCPServer {
        let tools = HangarTools(api: api)
        let url = api.baseURL
        return MCPServer(
            name: "hangar", version: HangarVersion.current, instructions: HangarTools.instructions, tools: tools.all,
            describe: { HangarTools.describe($0, server: url) })
    }
}
