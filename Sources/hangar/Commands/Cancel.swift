import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Cancel: HangarCommand {
    static let configuration = CommandConfiguration(abstract: "Cancel a build's queued and running jobs.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The build's ID.") var buildID: UUID

    func run(_ cli: CLI) async throws {
        let build = try await cli.api.cancelBuild(buildID)
        if cli.json { return try cli.printJSON(build) }
        cli.print("Cancel requested for build \(build.buildNumber); it is \(build.status.rawValue).")
    }
}
