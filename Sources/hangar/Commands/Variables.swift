import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Variables: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "var", abstract: "Set, list and remove variables. Values are write-only.",
        subcommands: [Set.self, List.self, Remove.self])

    struct Set: HangarCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a variable from --value, --value-file or stdin. The value is never printed.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The variable's name.") var name: String
        @Option(help: "The app's slug or ID. Default: a global variable.") var app: String?
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
            try await cli.api.setVariable(name, VariableInput(value: resolved, isSecret: secret, asFile: asFile), app: app)
            if cli.json { return }
            let flags = [secret ? "secret" : nil, asFile ? "as file" : nil].compactMap(\.self)
            cli.print("Set \(name)\(flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))") \(app.map { "for \($0)" } ?? "globally").")
        }
    }

    struct List: HangarCommand {
        static let configuration = CommandConfiguration(abstract: "List variable names and flags, never values.")
        @OptionGroup var global: GlobalOptions
        @Option(help: "The app's slug or ID. Default: the global variables.") var app: String?

        func run(_ cli: CLI) async throws {
            let variables = try await cli.api.variables(app: app)
            if cli.json { return try cli.printJSON(variables) }
            guard !variables.isEmpty else { return cli.print("No variables.") }
            let rows = variables.map {
                [$0.name, $0.isSecret ? "yes" : "no", $0.asFile ? "yes" : "no", Format.dateTime($0.updatedAt, timeZone: cli.timeZone)]
            }
            cli.print(Table(headers: ["NAME", "SECRET", "AS FILE", "UPDATED"], rows: rows).render(bold: cli.console.isTTY))
        }
    }

    struct Remove: HangarCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a variable.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The variable's name.") var name: String
        @Option(help: "The app's slug or ID. Default: a global variable.") var app: String?

        func run(_ cli: CLI) async throws {
            try await cli.api.deleteVariable(name, app: app)
            if !cli.json { cli.print("Removed \(name).") }
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
