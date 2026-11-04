import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Workflows: HangarCommand {
    static let configuration = CommandConfiguration(abstract: "Show the workflows in an app's .hangar.yml at a ref.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The app's slug or ID.") var app: String
    @Option(help: "The branch, tag or commit to read .hangar.yml at.") var ref = "main"

    func run(_ cli: CLI) async throws {
        let response = try await cli.api.workflows(app: app, ref: ref)
        if cli.json { return try cli.printJSON(response) }
        cli.print(Self.render(response, ref: ref))
    }

    static func render(_ response: WorkflowsResponse, ref: String) -> String {
        var lines = ["\(WorkflowFile.path) at \(ref) (\(Format.shortCommit(response.commit)))"]
        for (name, workflow) in response.workflows.workflows.sorted(by: { $0.key < $1.key }) {
            lines.append("")
            lines.append("\(name)  Xcode \(workflow.xcode)" + (workflow.teamID.map { "  team \($0)" } ?? ""))
            for action in workflow.actions { lines.append("  \(Format.label(action))  \(action.export.rawValue)") }
            if !workflow.postActions.isEmpty {
                lines.append("  post-actions: " + workflow.postActions.map(\.name).joined(separator: ", "))
            }
        }
        return lines.joined(separator: "\n")
    }
}
