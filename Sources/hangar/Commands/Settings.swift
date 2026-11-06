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
            abstract: "Store the server's App Store Connect API key (Settings › App Store Connect).",
            discussion: """
                The server tests the key with App Store Connect before it stores it. It is a server setting, not a \
                variable: jobs never get it in their environment. A team key has an issuer ID; xcodebuild signs and \
                uploads with it. An individual key has none: omit --issuer-id, and xcodebuild signs with the Xcode \
                account signed in on each worker Mac.
                """)
        @OptionGroup var global: GlobalOptions
        @Option(help: "The key's ID.") var keyId: String
        @Option(help: "The issuer ID of a team key; omit it for an individual key.") var issuerId: String?
        @Option(help: "The AuthKey_<id>.p8 file.") var p8: String

        func run(_ cli: CLI) async throws {
            guard let data = FileManager.default.contents(atPath: p8), let key = String(data: data, encoding: .utf8) else {
                throw CLIError("cannot read \(p8)")
            }
            let result = try await cli.api.saveASCKey(SaveASCKeyRequest(keyID: keyId, issuerID: issuerId, privateKey: key))
            if !cli.json {
                cli.print("Stored the App Store Connect \(result.kind == .team ? "team" : "individual") key \(result.keyID).")
            }
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
