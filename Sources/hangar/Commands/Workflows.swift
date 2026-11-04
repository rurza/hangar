import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Workflows: HangarCommand {
    static let configuration = CommandConfiguration(abstract: "Show an app's workflows, or define them in Hangar with --set or --clear.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The app's slug or ID.") var app: String
    @Option(help: "The branch, tag or commit to read .hangar.yml at.") var ref = "main"
    @Option(help: "Define the app's workflows in Hangar from this YAML file (same format as .hangar.yml).") var set: String?
    @Flag(help: "Remove the workflows defined in Hangar; the repository's .hangar.yml is used again.") var clear = false

    func validate() throws {
        if set != nil && clear { throw ValidationError("--set and --clear cannot be combined.") }
    }

    func run(_ cli: CLI) async throws {
        if let set {
            guard let data = FileManager.default.contents(atPath: set) else { throw CLIError("cannot read \(set)") }
            guard let yaml = String(data: data, encoding: .utf8) else { throw CLIError("\(set) is not UTF-8 text") }
            let stored = try await cli.api.setWorkflowFile(app: app, yaml: yaml)
            if cli.json { return try cli.printJSON(stored) }
            let names = stored.workflows.workflows.keys.sorted().joined(separator: ", ")
            return cli.print("Workflows defined in Hangar: \(names)")
        }
        if clear {
            try await cli.api.clearWorkflowFile(app: app)
            if !cli.json { cli.print("Removed the workflows defined in Hangar.") }
            return
        }
        let response = try await cli.api.workflows(app: app, ref: ref)
        if cli.json { return try cli.printJSON(response) }
        cli.print(Self.render(response, ref: ref))
    }

    static func render(_ response: WorkflowsResponse, ref: String) -> String {
        let source =
            switch response.source {
            case .hangar: "defined in Hangar"
            case .repository: "\(WorkflowFile.path) at \(Format.shortCommit(response.commit))"
            }
        var lines = ["Source: \(source)", "At \(ref) (\(Format.shortCommit(response.commit)))"]
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
