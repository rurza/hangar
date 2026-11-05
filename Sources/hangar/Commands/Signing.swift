import ArgumentParser
import Foundation
import HangarClient
import HangarCore

/// The server's one Apple Development identity, which VM archives sign with.
struct Signing: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show, create, import or remove the server's signing certificate for VM builds.",
        discussion: """
            VM archives sign with one Apple Development identity kept on the server. Hangar creates it only when you \
            ask, through the App Store Connect team key, or you import a .p12 you already have. Distribution signing \
            is not affected: exports stay cloud-managed by App Store Connect.
            """,
        subcommands: [Show.self, Create.self, Import.self, Remove.self], defaultSubcommand: Show.self)

    static let createExplanation = """
        This creates one Apple Development certificate for your team through the App Store Connect API. VM builds \
        sign development archives with it; it does not touch your apps, your other certificates or distribution \
        signing. Hangar creates no more until it is within 30 days of expiring.
        """

    struct Show: HangarCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the signing certificate.")
        @OptionGroup var global: GlobalOptions

        func run(_ cli: CLI) async throws {
            let status = try await cli.api.signingStatus()
            if cli.json { return try cli.printJSON(status) }
            cli.print(Self.render(status, timeZone: cli.timeZone))
        }

        static func render(_ status: SigningStatus, timeZone: TimeZone) -> String {
            guard let identity = status.identity else {
                return "No signing certificate: VM archives wait until there is one.\n"
                    + "Create one with `hangar signing create`, or import a .p12 with `hangar signing import <file>`."
            }
            let state = switch status.state {
            case .active, .none: "active"
            case .expiring: "expiring soon"
            case .expired: "expired"
            }
            var lines = [
                "\(identity.name)",
                "  status:   \(state), until \(Format.dateTime(identity.expiresAt, timeZone: timeZone))",
                "  team:     \(identity.teamID ?? "unknown")",
                "  serial:   \(identity.serialNumber)",
                "  origin:   " + (identity.origin == .created
                    ? "created by Hangar \(Format.dateTime(identity.createdAt, timeZone: timeZone))"
                        + (identity.ascCertificateID.map { " (App Store Connect ID \($0))" } ?? "")
                    : "imported \(Format.dateTime(identity.createdAt, timeZone: timeZone))"),
            ]
            if status.canCreate { lines.append("Renew it with `hangar signing create`.") }
            return lines.joined(separator: "\n")
        }
    }

    struct Create: HangarCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create Hangar's signing certificate, or renew it in its last 30 days.",
            discussion: createExplanation + " Renewing revokes the old certificate only if Hangar created it.")
        @OptionGroup var global: GlobalOptions
        @Flag(help: "Confirm: create the certificate.") var yes = false

        func run(_ cli: CLI) async throws {
            guard yes else {
                cli.printError(createExplanation)
                throw CLIError("run again with --yes to create it")
            }
            let response = try await cli.api.createSigningCertificate()
            if cli.json { return try cli.printJSON(response) }
            cli.print("Created Hangar's signing certificate.")
            cli.print(Show.render(response.status, timeZone: cli.timeZone))
            if let revoked = response.revokedCertificateID { cli.print("Revoked the previous Hangar certificate \(revoked).") }
            if let problem = response.revokeProblem { cli.printError("warning: \(problem)") }
        }
    }

    struct Import: HangarCommand {
        static let configuration = CommandConfiguration(
            abstract: "Use a .p12 you already have (an Apple Development certificate with its key); creates nothing.",
            discussion: "The password comes from HANGAR_P12_PASSWORD, else from stdin. The server keeps the identity sealed and packs it under a password of its own.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The .p12 file exported from Keychain Access.") var file: String

        func run(_ cli: CLI) async throws {
            guard let data = FileManager.default.contents(atPath: file) else { throw CLIError("cannot read \(file)") }
            let password = try cli.context.environment["HANGAR_P12_PASSWORD"]
                ?? SecretInput.read(value: nil, file: nil, console: cli.console)
            let status = try await cli.api.importSigningIdentity(p12: data, password: password)
            if cli.json { return try cli.printJSON(status) }
            cli.print("Imported the signing certificate.")
            cli.print(Show.render(status, timeZone: cli.timeZone))
        }
    }

    struct Remove: HangarCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete the server's stored copy. The certificate is not revoked.")
        @OptionGroup var global: GlobalOptions
        @Flag(help: "Confirm: delete the stored copy.") var yes = false

        func run(_ cli: CLI) async throws {
            guard yes else {
                cli.printError("This deletes Hangar's copy of the certificate; VM archives wait until there is another. It stays valid at Apple: revoke it in the Apple Developer website if you no longer need it.")
                throw CLIError("run again with --yes to remove it")
            }
            let status = try await cli.api.removeSigningIdentity()
            if cli.json { return try cli.printJSON(status) }
            cli.print("Removed the stored signing certificate (not revoked).")
        }
    }
}
