import ArgumentParser
import Foundation
import HangarClient
import HangarCore

struct Deploy: HangarCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a build of an app's workflow.",
        discussion: """
            In a terminal (or with --watch) the build is watched until it ends. --no-wait and --json return as \
            soon as the build is queued.

            Exit codes: 0 the build succeeded (or was queued, when not watching); 1 the build failed, or the \
            request failed; 2 the build was cancelled; 3 the watch lost contact with the server for about two \
            minutes and the build is still queued or running; 64 usage error.
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
        switch await BuildWatcher(cli: cli).watch(build, events: events) {
        case .finished(let finished):
            try BuildWatcher.exit(for: finished.status)
        case .lostContact(let last):
            cli.printError(
                "error: lost contact with the server; build \(last.id.uuidString.lowercased()) is still \(last.status.rawValue)")
            throw ExitCode(3)
        }
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
