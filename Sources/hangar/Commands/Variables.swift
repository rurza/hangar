import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Variables: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "var", abstract: "Set, list and remove variables, groups and links. Values are write-only.",
        discussion: """
            A job of workflow W gets each name from the first of: an app variable limited to W, the app variable for \
            all workflows, a group linked for W, a group linked for all workflows, a global variable. Between two \
            linked groups, the one linked first wins.
            """,
        subcommands: [Set.self, List.self, Remove.self, Group.self, Link.self, Unlink.self])

    /// Where a variable lives: an app, a group, or the global scope.
    struct Target: ParsableArguments {
        @Option(help: "The app's slug or ID. Default: a global variable.") var app: String?
        @Option(help: "A variable group's name or ID, instead of an app.") var group: String?
        @Option(
            name: .customLong("workflow"),
            help: "With --app: only jobs of this workflow get it. Repeat for several; none means all workflows.")
        var workflows: [String] = []

        func validate() throws {
            if app != nil, group != nil { throw ValidationError("Pass --app or --group, not both.") }
            if !workflows.isEmpty, app == nil {
                throw ValidationError("--workflow needs --app: only app variables are limited to workflows.")
            }
        }

        var label: String {
            if let group { return "in group \(group)" }
            guard let app else { return "globally" }
            return workflows.isEmpty ? "for \(app)" : "for \(app) (\(workflows.joined(separator: ", ")))"
        }
    }

    struct Set: HangarCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a variable from --value, --value-file or stdin. The value is never printed.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The variable's name.") var name: String
        @OptionGroup var target: Target
        @Flag(help: "Store the value encrypted and mask it in logs.") var secret = false
        @Flag(help: "Give jobs a path to a file holding the value instead of the value.") var asFile = false
        @Option(help: "The value. With --secret prefer --value-file or stdin: this may land in shell history.")
        var value: String?
        @Option(help: "Read the value from this file.") var valueFile: String?

        func validate() throws {
            if value != nil, valueFile != nil { throw ValidationError("Pass --value or --value-file, not both.") }
        }

        func run(_ cli: CLI) async throws {
            if value != nil, secret {
                cli.printError("warning: --value may leave the secret in your shell history; prefer --value-file or stdin.")
            }
            let resolved = try SecretInput.read(value: value, file: valueFile, console: cli.console)
            let input = VariableInput(value: resolved, isSecret: secret, asFile: asFile, workflows: target.workflows)
            if let group = target.group {
                try await cli.api.setGroupVariable(name, input, group: group)
            } else {
                try await cli.api.setVariable(name, input, app: target.app)
            }
            if cli.json { return }
            let flags = [secret ? "secret" : nil, asFile ? "as file" : nil].compactMap(\.self)
            cli.print("Set \(name)\(flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))") \(target.label).")
        }
    }

    struct List: HangarCommand {
        static let configuration = CommandConfiguration(
            abstract: "List variable names and flags, never values.",
            discussion: "With --app and --workflow: what a job of that workflow gets, and where each name comes from.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: Target

        func validate() throws {
            if target.workflows.count > 1 { throw ValidationError("List takes one --workflow.") }
        }

        func run(_ cli: CLI) async throws {
            if let app = target.app, let workflow = target.workflows.first {
                return try await environment(cli, app: app, workflow: workflow)
            }
            let variables: [VariableSummary]
            if let group = target.group {
                variables = try await cli.api.variableGroup(group).variables
            } else {
                variables = try await cli.api.variables(app: target.app)
            }
            if cli.json { return try cli.printJSON(variables) }
            if variables.isEmpty {
                cli.print("No variables.")
            } else {
                var headers = ["NAME", "SECRET", "AS FILE", "UPDATED"]
                if target.app != nil { headers.insert("WORKFLOWS", at: 1) }
                let rows = variables.map { variable in
                    var row = [
                        variable.name, variable.isSecret ? "yes" : "no", variable.asFile ? "yes" : "no",
                        Format.dateTime(variable.updatedAt, timeZone: cli.timeZone),
                    ]
                    if target.app != nil { row.insert(Variables.workflowsText(variable.workflows), at: 1) }
                    return row
                }
                cli.print(Table(headers: headers, rows: rows).render(bold: cli.console.isTTY))
            }
            if let app = target.app {
                let links = try await cli.api.variableGroupLinks(app: app)
                guard !links.isEmpty else { return }
                cli.print("")
                cli.print("Linked groups, the first wins a name two share:")
                for link in links {
                    let names = link.variables.map(\.name)
                    cli.print("  \(link.name) (\(Variables.workflowsText(link.workflows))): \(names.isEmpty ? "no variables" : names.joined(separator: ", "))")
                }
            }
        }

        private func environment(_ cli: CLI, app: String, workflow: String) async throws {
            let effective = try await cli.api.environment(app: app, workflow: workflow)
            if cli.json { return try cli.printJSON(effective) }
            guard !effective.isEmpty else { return cli.print("Jobs of \(workflow) get no variables.") }
            let rows = effective.map {
                [$0.name, $0.isSecret ? "yes" : "no", $0.asFile ? "yes" : "no", Variables.sourceText($0.source)]
            }
            cli.print(Table(headers: ["NAME", "SECRET", "AS FILE", "FROM"], rows: rows).render(bold: cli.console.isTTY))
        }
    }

    struct Remove: HangarCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a variable.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The variable's name.") var name: String
        @OptionGroup var target: Target

        func run(_ cli: CLI) async throws {
            if let group = target.group {
                try await cli.api.deleteGroupVariable(name, group: group)
            } else {
                try await cli.api.deleteVariable(name, app: target.app, workflows: target.workflows)
            }
            if !cli.json { cli.print("Removed \(name) \(target.label).") }
        }
    }

    struct Link: HangarCommand {
        static let configuration = CommandConfiguration(
            abstract: "Link a variable group to an app, or change the workflows of a link.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The group's name or ID.") var group: String
        @Option(help: "The app's slug or ID.") var app: String
        @Option(name: .customLong("workflow"), help: "Only jobs of this workflow get the group. Repeat for several.")
        var workflows: [String] = []

        func run(_ cli: CLI) async throws {
            try await cli.api.linkVariableGroup(group, app: app, workflows: workflows)
            if !cli.json { cli.print("Linked \(group) to \(app) for \(Variables.workflowsText(workflows)).") }
        }
    }

    struct Unlink: HangarCommand {
        static let configuration = CommandConfiguration(abstract: "Unlink a variable group from an app.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The group's name or ID.") var group: String
        @Option(help: "The app's slug or ID.") var app: String

        func run(_ cli: CLI) async throws {
            try await cli.api.unlinkVariableGroup(group, app: app)
            if !cli.json { cli.print("Unlinked \(group) from \(app).") }
        }
    }

    struct Group: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Variable groups: variables defined once, used by the apps that link them.",
            subcommands: [Create.self, GroupList.self, Rename.self, GroupRemove.self])

        struct Create: HangarCommand {
            static let configuration = CommandConfiguration(abstract: "Create an empty group.")
            @OptionGroup var global: GlobalOptions
            @Argument(help: "The group's name.") var name: String

            func run(_ cli: CLI) async throws {
                let group = try await cli.api.createVariableGroup(name: name)
                if cli.json { return try cli.printJSON(group) }
                cli.print("Created \(group.name). Add variables with hangar var set NAME --group \"\(group.name)\".")
            }
        }

        struct GroupList: HangarCommand {
            static let configuration = CommandConfiguration(commandName: "list", abstract: "List groups and the apps that link them.")
            @OptionGroup var global: GlobalOptions

            func run(_ cli: CLI) async throws {
                let groups = try await cli.api.variableGroups()
                if cli.json { return try cli.printJSON(groups) }
                guard !groups.isEmpty else { return cli.print("No variable groups.") }
                let rows = groups.map { group in
                    [
                        group.name, group.variables.map(\.name).joined(separator: ", "),
                        group.apps.map { "\($0.slug) (\(Variables.workflowsText($0.workflows)))" }.joined(separator: ", "),
                    ]
                }
                cli.print(Table(headers: ["NAME", "VARIABLES", "LINKED BY"], rows: rows).render(bold: cli.console.isTTY))
            }
        }

        struct Rename: HangarCommand {
            static let configuration = CommandConfiguration(abstract: "Rename a group.")
            @OptionGroup var global: GlobalOptions
            @Argument(help: "The group's name or ID.") var group: String
            @Argument(help: "The new name.") var name: String

            func run(_ cli: CLI) async throws {
                let renamed = try await cli.api.renameVariableGroup(group, to: name)
                if !cli.json { cli.print("Renamed \(group) to \(renamed.name).") }
            }
        }

        struct GroupRemove: HangarCommand {
            static let configuration = CommandConfiguration(
                commandName: "remove", abstract: "Delete a group with its variables; the apps that link it lose them.")
            @OptionGroup var global: GlobalOptions
            @Argument(help: "The group's name or ID.") var group: String

            func run(_ cli: CLI) async throws {
                try await cli.api.deleteVariableGroup(group)
                if !cli.json { cli.print("Deleted \(group).") }
            }
        }
    }

    /// "all workflows", "Beta, Release".
    static func workflowsText(_ workflows: [String]) -> String {
        workflows.isEmpty ? "all workflows" : workflows.joined(separator: ", ")
    }

    /// "app", "app (Beta)", "group Sentry", "group Sentry (Beta)", "global".
    static func sourceText(_ source: VariableSource) -> String {
        let limited = source.workflows.isEmpty ? "" : " (\(source.workflows.joined(separator: ", ")))"
        switch source.kind {
        case .app: return "app\(limited)"
        case .group: return "group \(source.group ?? "?")\(limited)"
        case .global: return "global"
        }
    }
}

/// Reads a variable's value without ever echoing it.
enum SecretInput {
    /// `value` as given; else the file's contents; else stdin. One trailing newline is stripped from a file or stdin.
    static func read(value: String?, file: String?, console: Console) throws -> String {
        if let value { return value }
        let data: Data
        if let file {
            guard let contents = FileManager.default.contents(atPath: file) else { throw CLIError("cannot read \(file)") }
            data = contents
        } else {
            data = console.readInput()
        }
        guard var text = String(data: data, encoding: .utf8) else { throw CLIError("the value is not UTF-8 text") }
        if text.hasSuffix("\r\n") { text.removeLast(2) } else if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
