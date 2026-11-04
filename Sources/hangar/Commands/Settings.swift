import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Settings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set the server-wide credentials Hangar needs.", subcommands: [AscKey.self, GitHubToken.self])

    struct AscKey: HangarCommand {
        static let configuration = CommandConfiguration(
            commandName: "asc-key",
            abstract: "Store the App Store Connect API key as HANGAR_ASC_KEY_ID, HANGAR_ASC_ISSUER_ID and HANGAR_ASC_KEY_PATH.",
            discussion: """
                A team key has an issuer ID; xcodebuild signs and uploads with it. An individual key has none: omit \
                --issuer-id, and xcodebuild signs with the Xcode account signed in on each worker Mac.
                """)
        @OptionGroup var global: GlobalOptions
        @Option(help: "The key's ID.") var keyId: String
        @Option(help: "The issuer ID of a team key; omit it for an individual key.") var issuerId: String?
        @Option(help: "The AuthKey_<id>.p8 file; its contents are stored as a secret file.") var p8: String

        func run(_ cli: CLI) async throws {
            guard let data = FileManager.default.contents(atPath: p8), let key = String(data: data, encoding: .utf8) else {
                throw CLIError("cannot read \(p8)")
            }
            try await cli.api.setVariable("HANGAR_ASC_KEY_ID", VariableInput(value: keyId))
            if let issuerId {
                try await cli.api.setVariable("HANGAR_ASC_ISSUER_ID", VariableInput(value: issuerId))
            } else {
                // Switching from a team key to an individual one: a stale issuer would make it look like a team key.
                try await cli.api.deleteVariable("HANGAR_ASC_ISSUER_ID")
            }
            try await cli.api.setVariable("HANGAR_ASC_KEY_PATH", VariableInput(value: key, isSecret: true, asFile: true))
            if !cli.json { cli.print("Stored the App Store Connect \(issuerId == nil ? "individual" : "team") key \(keyId).") }
        }
    }

    struct GitHubToken: HangarCommand {
        static let configuration = CommandConfiguration(
            commandName: "github-token", abstract: "Store a GitHub token, read from stdin, as HANGAR_GITHUB_TOKEN.")
        @OptionGroup var global: GlobalOptions

        func run(_ cli: CLI) async throws {
            let token = try SecretInput.read(value: nil, file: nil, console: cli.console)
            guard !token.isEmpty else { throw CLIError("no token on stdin") }
            try await cli.api.setVariable("HANGAR_GITHUB_TOKEN", VariableInput(value: token, isSecret: true))
            if !cli.json { cli.print("Stored the GitHub token.") }
        }
    }
}
