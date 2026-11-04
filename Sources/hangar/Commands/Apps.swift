import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Apps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, add and remove apps.", subcommands: [List.self, Add.self, Remove.self])

    struct List: HangarCommand {
        static let configuration = CommandConfiguration(abstract: "List the apps.")
        @OptionGroup var global: GlobalOptions

        func run(_ cli: CLI) async throws {
            let apps = try await cli.api.apps()
            if cli.json { return try cli.printJSON(apps) }
            guard !apps.isEmpty else { return cli.print("No apps. Add one with: hangar apps add <name> --repo <url> --asc-app-id <id>") }
            let rows = apps.map { [$0.slug, $0.name, $0.repoURL, $0.appStoreConnectAppID] }
            cli.print(Table(headers: ["SLUG", "NAME", "REPOSITORY", "ASC APP ID"], rows: rows).render(bold: cli.console.isTTY))
        }
    }

    struct Add: HangarCommand {
        static let configuration = CommandConfiguration(abstract: "Add an app.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The app's name; its slug is derived from it.") var name: String
        @Option(help: "The GitHub repository URL.") var repo: String
        @Option(help: "The App Store Connect app ID.") var ascAppId: String
        @Option(help: "An icon image URL.") var icon: String?

        func run(_ cli: CLI) async throws {
            let app = try await cli.api.createApp(
                CreateAppRequest(name: name, repoURL: repo, appStoreConnectAppID: ascAppId, iconURL: icon))
            if cli.json { return try cli.printJSON(app) }
            cli.print("Added \(app.name) as '\(app.slug)'.")
        }
    }

    struct Remove: HangarCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove an app with its builds, jobs, numbers and variables.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The app's slug or ID.") var app: String

        func run(_ cli: CLI) async throws {
            try await cli.api.deleteApp(app)
            if !cli.json { cli.print("Removed \(app).") }
        }
    }
}
