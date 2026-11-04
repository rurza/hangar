import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Builds: HangarCommand {
    static let configuration = CommandConfiguration(abstract: "List recent builds, newest first.")
    @OptionGroup var global: GlobalOptions
    @Option(help: "Only this app's builds (slug or ID).") var app: String?
    @Option(help: "How many builds, at most 200.") var limit = 20

    func run(_ cli: CLI) async throws {
        let builds = try await cli.api.builds(app: app, limit: limit)
        if cli.json { return try cli.printJSON(builds) }
        guard !builds.isEmpty else { return cli.print("No builds.") }
        let apps = try await cli.api.apps()
        cli.print(Self.render(builds, apps: apps, timeZone: cli.timeZone, bold: cli.console.isTTY))
    }

    static func render(_ builds: [Build], apps: [App], timeZone: TimeZone, bold: Bool = false) -> String {
        let rows = builds.map { build in
            [
                "\(build.buildNumber)", Status.appName(build.appID, apps), build.workflow, build.ref,
                Format.shortCommit(build.commit), build.status.rawValue, Format.dateTime(build.createdAt, timeZone: timeZone),
                build.id.uuidString.lowercased(),
            ]
        }
        return Table(headers: ["BUILD", "APP", "WORKFLOW", "REF", "COMMIT", "STATUS", "CREATED", "ID"], rows: rows)
            .render(bold: bold)
    }
}
