import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Status: HangarCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show queued and running builds, or one build's jobs and steps.",
        discussion: "With a build ID the exit code is 1 when the build failed and 2 when it was cancelled.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "A build ID. Default: every queued or running build.") var buildID: UUID?

    func run(_ cli: CLI) async throws {
        guard let buildID else {
            let active = try await cli.api.builds(limit: 200).filter { $0.status == .queued || $0.status == .running }
            if cli.json { return try cli.printJSON(active) }
            let (apps, machines) = active.isEmpty ? ([], []) : (try await cli.api.apps(), try await cli.api.machines())
            return cli.print(Self.renderActive(active, apps: apps, machines: machines, bold: cli.console.isTTY))
        }
        let build = try await cli.api.build(buildID)
        if cli.json {
            try cli.printJSON(build)
        } else {
            let (apps, machines) = (try await cli.api.apps(), try await cli.api.machines())
            cli.print(Self.renderDetail(build, apps: apps, machines: machines, now: Date(), timeZone: cli.timeZone))
        }
        try BuildWatcher.exit(for: build.status)
    }

    /// One row per job of the given builds, with the machine, the current step and why a queued job waits.
    static func renderActive(_ builds: [Build], apps: [App], machines: [Machine], bold: Bool = false) -> String {
        guard !builds.isEmpty else { return "No queued or running builds." }
        let rows = builds.flatMap { build in
            build.jobs.map { job in
                [
                    "\(build.buildNumber)", appName(build.appID, apps), build.workflow, Format.label(job.action),
                    job.status.rawValue, machineName(job.machineID, machines), currentStep(job) ?? "-",
                    build.id.uuidString.lowercased(), job.queueNote ?? "",
                ]
            }
        }
        return Table(headers: ["BUILD", "APP", "WORKFLOW", "JOB", "STATUS", "MACHINE", "STEP", "ID", "NOTE"], rows: rows)
            .render(bold: bold)
    }

    /// The build's header, then each job's steps with start times and durations.
    static func renderDetail(_ build: Build, apps: [App], machines: [Machine], now: Date, timeZone: TimeZone) -> String {
        var lines = [
            "Build \(build.buildNumber) \(build.status.rawValue): \(appName(build.appID, apps)) \(build.workflow) at \(build.ref) (\(Format.shortCommit(build.commit)))",
            "ID: \(build.id.uuidString.lowercased())",
            "Created \(Format.dateTime(build.createdAt, timeZone: timeZone))"
                + (build.finishedAt.map { ", finished \(Format.dateTime($0, timeZone: timeZone))" } ?? ""),
        ]
        for job in build.jobs {
            lines.append("")
            var heading = "[\(Format.label(job.action))] \(job.status.rawValue)"
            if job.machineID != nil { heading += " on \(machineName(job.machineID, machines))" }
            if let note = job.queueNote { heading += ": \(note)" }
            if let reason = job.failureReason { heading += ": \(reason)" }
            lines.append(heading + "  (job \(job.id.uuidString.lowercased()))")
            guard !job.steps.isEmpty else { continue }
            let rows = job.steps.map { step in
                [
                    step.name, step.status.rawValue,
                    step.startedAt.map { Format.time($0, timeZone: timeZone) } ?? "-",
                    step.startedAt.map { Format.duration((step.finishedAt ?? now).timeIntervalSince($0)) } ?? "-",
                ]
            }
            lines.append(Table(headers: ["STEP", "STATUS", "STARTED", "DURATION"], rows: rows).render())
        }
        return lines.joined(separator: "\n")
    }

    /// The running step, else the last one that started.
    static func currentStep(_ job: Job) -> String? {
        (job.steps.first { $0.status == .running } ?? job.steps.last { $0.status != .pending })?.name
    }

    static func appName(_ id: UUID, _ apps: [App]) -> String {
        apps.first { $0.id == id }?.slug ?? Format.shortID(id)
    }

    static func machineName(_ id: UUID?, _ machines: [Machine]) -> String {
        guard let id else { return "-" }
        return machines.first { $0.id == id }?.name ?? Format.shortID(id)
    }
}
