import ArgumentParser
import Foundation
import HangarClient
import HangarCore

extension APITokenScope: ExpressibleByArgument {}

struct Tokens: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, create and revoke API tokens for agents (hangar mcp).",
        subcommands: [List.self, Create.self, Revoke.self])

    struct List: HangarCommand {
        static let configuration = CommandConfiguration(abstract: "List API tokens; never their secrets.")
        @OptionGroup var global: GlobalOptions

        func run(_ cli: CLI) async throws {
            let tokens = try await cli.api.apiTokens()
            if cli.json { return try cli.printJSON(tokens) }
            guard !tokens.isEmpty else {
                return cli.print("No API tokens. Create one with: hangar tokens create <name> --scope deploy")
            }
            cli.print(Self.render(tokens, timeZone: cli.timeZone, bold: cli.console.isTTY))
        }

        static func render(_ tokens: [APIToken], timeZone: TimeZone, bold: Bool = false) -> String {
            let rows = tokens.map { token in
                [
                    token.name, token.scope.rawValue, token.prefix + "…",
                    Format.dateTime(token.createdAt, timeZone: timeZone),
                    token.lastUsedAt.map { Format.dateTime($0, timeZone: timeZone) } ?? "never",
                ]
            }
            return Table(headers: ["NAME", "SCOPE", "TOKEN", "CREATED", "LAST USED"], rows: rows).render(bold: bold)
        }
    }

    struct Create: HangarCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create an API token and print its secret once.",
            discussion: """
                Scopes nest. read: look at apps, workflows, builds, logs and machines. deploy: also start and cancel \
                builds. configure: also add and delete apps, store workflows and create TestFlight groups. No token \
                can change variables, settings or machines, or manage tokens.
                """)
        @OptionGroup var global: GlobalOptions
        @Argument(help: "A name to recognise it by, such as the agent or the Mac it runs on.") var name: String
        @Option(help: "read, deploy or configure.") var scope: APITokenScope = .read

        func run(_ cli: CLI) async throws {
            let created = try await cli.api.createAPIToken(CreateAPITokenRequest(name: name, scope: scope))
            if cli.json { return try cli.printJSON(created) }
            cli.print("Created API token \(created.token.name) (\(created.token.scope.rawValue)).")
            cli.print("Token: \(created.secret)")
            cli.print("Save it now; it is not shown again. Give it to hangar mcp as HANGAR_API_TOKEN.")
        }
    }

    struct Revoke: HangarCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke an API token; it stops working at once.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The token's name or ID.") var token: String

        func run(_ cli: CLI) async throws {
            try await cli.api.revokeAPIToken(token)
            if !cli.json { cli.print("Revoked \(token).") }
        }
    }
}
