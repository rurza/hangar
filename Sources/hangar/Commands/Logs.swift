import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Logs: HangarCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print a job's log, or every job's log of a build, prefixed by scheme.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "A job ID or a build ID.") var id: UUID
    @Flag(help: "Keep printing new lines until the job ends.") var follow = false
    @Option(help: "Only this step's lines, such as archive or post-action:testflight.") var step: String?
    @Option(help: "Only the last N lines.") var tail: Int?

    func validate() throws {
        if follow, tail != nil { throw ValidationError("--tail does not apply with --follow.") }
        if let tail, tail < 1 { throw ValidationError("--tail must be at least 1.") }
    }

    func run(_ cli: CLI) async throws {
        let (jobs, isBuild) = try await resolve(cli.api)
        func prefix(_ job: Job) -> String? { isBuild ? job.action.scheme : nil }
        if follow {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for job in jobs {
                    let prefix = prefix(job)
                    group.addTask { [step] in
                        for try await entry in cli.api.followLog(jobID: job.id, step: step) {
                            cli.print(cli.json ? try Format.jsonLine(entry) : Format.logLine(entry, prefix: prefix, timeZone: cli.timeZone))
                        }
                    }
                }
                try await group.waitForAll()
            }
            return
        }
        var byJob: [String: [LogEntry]] = [:]
        for job in jobs {
            let entries = try await cli.api.log(jobID: job.id, step: step, tail: tail)
            byJob[job.id.uuidString] = entries
            if !cli.json {
                for entry in entries { cli.print(Format.logLine(entry, prefix: prefix(job), timeZone: cli.timeZone)) }
            }
        }
        if cli.json {
            try isBuild ? cli.printJSON(byJob) : cli.printJSON(byJob.values.first ?? [])
        }
    }

    /// The job with this ID, else the jobs of the build with this ID.
    private func resolve(_ api: HangarAPI) async throws -> (jobs: [Job], isBuild: Bool) {
        do {
            return ([try await api.job(id)], false)
        } catch HangarAPIError.server(let error, _) where error.code == "job_not_found" {
            do {
                return (try await api.build(id).jobs, true)
            } catch HangarAPIError.server(let error, _) where error.code == "build_not_found" {
                throw CLIError("no job or build has the ID \(id.uuidString.lowercased())")
            }
        }
    }
}
