import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Deploy: HangarCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a build of an app's workflow.",
        discussion: """
            In a terminal the build is watched until it ends: exit 0 when it succeeds, 1 when it fails, 2 when it \
            is cancelled. --no-wait and --json return as soon as the build is queued.
            """)
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The app's slug or ID.") var app: String
    @Argument(help: "The workflow's name in .hangar.yml.") var workflow: String
    @Option(help: "The branch, tag or commit to build.") var ref = "main"
    @Option(help: "Run only on this machine (name or ID).") var machine: String?
    @Flag(help: "Follow the build until it ends. Default when stdout is a terminal.") var watch = false
    @Flag(help: "Return once the build is queued.") var noWait = false

    func run(_ cli: CLI) async throws {
        let request = DeployRequest(app: app, workflow: workflow, ref: ref, machine: machine)
        guard !noWait, !cli.json, watch || cli.console.isTTY else {
            let build = try await cli.api.deploy(request)
            return cli.json ? try cli.printJSON(build) : cli.print(Self.summary(build))
        }
        // Subscribe before deploying so no transition is missed; the watcher also re-reads the build.
        let events = cli.api.events()
        let build = try await cli.api.deploy(request)
        cli.print(Self.summary(build))
        let finished = try await BuildWatcher(cli: cli).watch(build, events: events)
        try BuildWatcher.exit(for: finished.status)
    }

    static func summary(_ build: Build) -> String {
        var lines = [
            "Build \(build.buildNumber) \(build.status.rawValue): \(build.workflow) at \(build.ref) (\(Format.shortCommit(build.commit)))",
            "ID: \(build.id.uuidString.lowercased())",
        ]
        for job in build.jobs {
            lines.append("  [\(Format.label(job.action))] \(job.status.rawValue)" + (job.queueNote.map { ": \($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}

/// Follows a build to its end: `/events` for prompt updates, plus a re-read of the build right away and every
/// `pollInterval`, which covers events sent before the subscription took and a dropped event stream.
struct BuildWatcher {
    let cli: CLI

    private enum Update: Sendable {
        case build(Build)
        case job(Job)
        case failed(any Error)
    }

    /// Prints step transitions as they happen and, if the build failed, the failed steps' last 40 log lines.
    func watch(_ build: Build, events: AsyncThrowingStream<ServerEvent, any Error>) async throws -> Build {
        var progress = BuildProgress(build: build)
        emit(progress.apply(try await cli.api.build(build.id), timeZone: cli.timeZone))

        if !progress.isFinished {
            let (updates, continuation) = AsyncStream.makeStream(of: Update.self)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // When the stream drops, the poll below carries on alone.
                    do {
                        for try await event in events {
                            switch event {
                            case .build(let build): continuation.yield(.build(build))
                            case .job(let job): continuation.yield(.job(job))
                            case .machine: continue
                            }
                        }
                    } catch {}
                }
                group.addTask { [api = cli.api, interval = cli.context.pollInterval] in
                    do {
                        while true {
                            try await Task.sleep(for: interval)
                            continuation.yield(.build(try await api.build(build.id)))
                        }
                    } catch is CancellationError {} catch {
                        continuation.yield(.failed(error))
                    }
                }
                for await update in updates {
                    switch update {
                    case .build(let snapshot): emit(progress.apply(snapshot, timeZone: cli.timeZone))
                    case .job(let job): emit(progress.apply(job, timeZone: cli.timeZone))
                    case .failed(let error): throw error
                    }
                    if progress.isFinished { break }
                }
                group.cancelAll()
            }
        }

        let finished = progress.build
        if finished.status == .failed { try await printFailures(finished) }
        cli.print("Build \(finished.buildNumber) \(finished.status.rawValue).")
        return finished
    }

    private func printFailures(_ build: Build) async throws {
        for job in build.jobs where job.status == .failed {
            let step = job.steps.first { $0.status == .failed }?.name
            let label = Format.label(job.action)
            cli.print("[\(label)] failed" + (step.map { " in \($0)" } ?? "") + (job.failureReason.map { ": \($0)" } ?? ""))
            let tail = try await cli.api.log(jobID: job.id, step: step, tail: 40)
            guard !tail.isEmpty else { continue }
            cli.print("Last \(tail.count) log lines\(step.map { " of \($0)" } ?? ""):")
            for entry in tail { cli.print(Format.logLine(entry, timeZone: cli.timeZone)) }
        }
    }

    private func emit(_ lines: [String]) {
        for line in lines { cli.print(line) }
    }

    /// Exit code 0 for a succeeded, queued or running build, 1 for a failed one, 2 for a cancelled one.
    static func exit(for status: BuildStatus) throws {
        switch status {
        case .failed: throw ExitCode.failure
        case .cancelled: throw ExitCode(2)
        case .queued, .running, .succeeded: return
        }
    }
}
