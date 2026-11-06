import ArgumentParser
import Foundation
import HangarCore
import HangarServer

extension APITokenScope: ExpressibleByArgument {}

extension HangarServerCommand {
    /// `hangar-server token create`: an API token made straight in the database, for when no owner device can reach
    /// the API (Tailscale down, a tagged server node, the CLI on loopback). The only way to make an `owner` token.
    struct Token: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make API tokens on the server Mac, without the API.", subcommands: [Create.self])

        struct Create: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Create an API token and print its secret once.",
                discussion: """
                    Run it on the server Mac as the user the server runs as. The secret goes to stdout and nothing \
                    else; save it to a file the CLI reads instead of pasting it into a command line:

                      (umask 077; mkdir -p ~/.config/hangar; hangar-server token create my-cli --scope owner > ~/.config/hangar/token)

                    Scopes: read, deploy, configure, owner. An owner token can do everything the owner can, secrets \
                    and machines included: keep it for your own CLI and never give it to an agent.
                    """)

            @Argument(help: "A name to recognise it by.") var name: String
            @Option(help: "read, deploy, configure or owner.") var scope: APITokenScope = .owner
            @Option(help: "The server's data directory. Default: $HANGAR_DATA_DIR, else ~/Library/Application Support/Hangar/server.")
            var dataDir: String?

            func run() async throws {
                let database = try HangarServerCommand.openDatabase(dataDir)
                let (token, secret) = try APITokenRepository(database: database).create(name: name, scope: scope)
                FileHandle.standardError.write(Data("Created API token \(token.name) (\(token.scope.rawValue)).\n".utf8))
                print(secret)
            }
        }
    }

    /// `hangar-server access`: the Tailscale logins that count as the owner, edited without the API (a login change,
    /// a tagged server node).
    struct Access: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or set the Tailscale logins that count as the owner.",
            discussion: """
                By default the owner is the login that owns this Mac's tailnet node. allow replaces that with the \
                logins given; reset goes back to the default. Takes effect at once, running server included.
                """,
            subcommands: [Show.self, Allow.self, Reset.self], defaultSubcommand: Show.self)

        struct Options: ParsableArguments {
            @Option(help: "The server's data directory. Default: $HANGAR_DATA_DIR, else ~/Library/Application Support/Hangar/server.")
            var dataDir: String?

            func access() throws -> OwnerAccess {
                OwnerAccess(
                    tailnet: TailscaleCLI(), settings: ServerSettingsRepository(database: try HangarServerCommand.openDatabase(dataDir)))
            }
        }

        struct Show: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Print the logins that count as the owner.")
            @OptionGroup var options: Options

            func run() async throws {
                let access = try options.access()
                if let configured = access.configuredLogins() {
                    print("Owner logins (set): \(configured.joined(separator: ", "))")
                } else if let node = await access.serverNode() {
                    print(node.tagged
                        ? "No owner login: this Mac's tailnet node is tagged. Set one with: hangar-server access allow <login>"
                        : "Owner login (this Mac's tailnet node): \(node.loginName)")
                } else {
                    print("No owner login: Tailscale is not running. Use an API token, or set one with: hangar-server access allow <login>")
                }
            }
        }

        struct Allow: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Make these logins the owner, replacing the list.")
            @OptionGroup var options: Options
            @Argument(help: "Tailscale logins, such as alice@github.") var logins: [String]

            func run() async throws {
                guard !logins.isEmpty else { throw ValidationError("Name at least one login; reset goes back to the default.") }
                do {
                    try options.access().setConfiguredLogins(logins)
                } catch let error as APIError {
                    throw ValidationError(error.message)
                }
                print("Owner logins: \(try OwnerAccess.validate(logins).joined(separator: ", "))")
            }
        }

        struct Reset: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Go back to the login that owns this Mac's tailnet node.")
            @OptionGroup var options: Options

            func run() async throws {
                try options.access().setConfiguredLogins(nil)
                print("Owner logins reset: the owner is the login that owns this Mac's tailnet node.")
            }
        }
    }
}
