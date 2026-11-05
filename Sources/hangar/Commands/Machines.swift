import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Machines: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, add, pause and remove worker machines.",
        subcommands: [List.self, Add.self, Pause.self, Resume.self, Remove.self])

    struct List: HangarCommand {
        static let configuration = CommandConfiguration(abstract: "List machines with their latest reports.")
        @OptionGroup var global: GlobalOptions

        func run(_ cli: CLI) async throws {
            let machines = try await cli.api.machines()
            if cli.json { return try cli.printJSON(machines) }
            guard !machines.isEmpty else { return cli.print("No machines. Add one with: hangar machines add <name>") }
            cli.print(Self.render(machines, now: Date(), timeZone: cli.timeZone, bold: cli.console.isTTY))
        }

        static func render(_ machines: [Machine], now: Date, timeZone: TimeZone, bold: Bool = false) -> String {
            let rows = machines.map { machine in
                let report = machine.report
                return [
                    machine.name,
                    (machine.isOnline(now: now) ? "online" : "offline") + (machine.paused ? ", paused" : ""),
                    "\(report?.runningJobIDs.count ?? 0)/\(machine.maxConcurrentJobs)",
                    report?.macOSVersion ?? "-",
                    report.map { $0.xcodes.map(\.version).joined(separator: ", ") } ?? "-",
                    report.map { String(format: "%.0f GB", $0.freeDiskGB) } ?? "-",
                    machine.lastSeenAt.map { Format.dateTime($0, timeZone: timeZone) } ?? "never",
                ]
            }
            return Table(headers: ["NAME", "STATE", "JOBS", "MACOS", "XCODE", "FREE DISK", "LAST SEEN"], rows: rows)
                .render(bold: bold)
        }
    }

    struct Add: HangarCommand {
        static let configuration = CommandConfiguration(abstract: "Add a machine and print its worker token once.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The machine's name.") var name: String
        @Option(help: "Jobs the machine runs at once.") var maxJobs = 1

        func run(_ cli: CLI) async throws {
            let created = try await cli.api.createMachine(CreateMachineRequest(name: name, maxConcurrentJobs: maxJobs))
            if cli.json { return try cli.printJSON(created) }
            cli.print("Added machine \(created.machine.name).")
            cli.print("Worker token: \(created.token)")
            cli.print("Save this token now; it is not shown again.")
        }
    }

    struct Pause: HangarCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn builds off on a machine: it takes no new jobs until resumed.",
            discussion: "A job it is running finishes. The worker stays installed and keeps reporting.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The machine's name or ID.") var machine: String

        func run(_ cli: CLI) async throws {
            let paused = try await cli.api.pauseMachine(machine)
            if cli.json { return try cli.printJSON(paused) }
            let running = paused.report?.runningJobIDs.count ?? 0
            cli.print("Paused \(paused.name): it takes no new builds"
                + (running > 0 ? "; the \(running == 1 ? "job" : "jobs") it is running \(running == 1 ? "finishes" : "finish") first." : "."))
            cli.print("Turn builds back on with: hangar machines resume \(paused.name)")
        }
    }

    struct Resume: HangarCommand {
        static let configuration = CommandConfiguration(abstract: "Turn builds on again on a paused machine.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The machine's name or ID.") var machine: String

        func run(_ cli: CLI) async throws {
            let resumed = try await cli.api.resumeMachine(machine)
            if cli.json { return try cli.printJSON(resumed) }
            cli.print("Resumed \(resumed.name): it takes builds again.")
        }
    }

    struct Remove: HangarCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a machine; its token stops working.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The machine's name or ID.") var machine: String

        func run(_ cli: CLI) async throws {
            try await cli.api.deleteMachine(machine)
            if !cli.json { cli.print("Removed \(machine).") }
        }
    }
}
