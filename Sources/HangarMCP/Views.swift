import Foundation
import HangarCore

/// The shapes tools return: what an agent needs to decide its next step, not every stored field.
enum Views {
    /// `list_variables` without a workflow: names and flags only. `workflows` empty means all workflows.
    struct Variables: Encodable {
        var variables: [Variable]
        /// In precedence order: the first wins a name two groups share.
        var linkedGroups: [LinkedGroup]
    }

    struct Variable: Encodable {
        var name: String
        var isSecret: Bool
        var asFile: Bool
        var workflows: [String]
    }

    struct LinkedGroup: Encodable {
        var name: String
        var workflows: [String]
        var variables: [String]
    }

    struct AppView: Encodable {
        var id: UUID
        var slug: String
        var name: String
        var repository: String
        var appStoreConnectAppID: String
        var url: String

        init(_ app: App, server: URL) {
            id = app.id
            slug = app.slug
            name = app.name
            repository = app.repoURL
            appStoreConnectAppID = app.appStoreConnectAppID
            url = Views.page(server, "apps/\(app.slug)")
        }
    }

    struct JobView: Encodable {
        var id: UUID
        var action: String
        var status: JobStatus
        var machine: String?
        var currentStep: String?
        var failedStep: String?
        var steps: [String]
        var queueNote: String?
        var failureReason: String?
        var tests: TestOutputs?
        /// A Developer ID archive's notarization: Apple's submission ID and its status ("Accepted").
        var notarization: Notarization?
        var startedAt: Date?
        var finishedAt: Date?
        /// The last lines of the failed step's log, for a failed job.
        var logExcerpt: [String]?
    }

    struct Notarization: Encodable, Equatable {
        var submissionID: String
        var status: String?

        init?(_ outputs: [String: String]) {
            guard let id = outputs["notarization.submissionID"], !id.isEmpty else { return nil }
            submissionID = id
            status = outputs["notarization.status"].flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    struct BuildView: Encodable {
        var id: UUID
        var app: String
        var workflow: String
        var ref: String
        var commit: String
        var buildNumber: Int
        var status: BuildStatus
        var finished: Bool
        var createdAt: Date
        var finishedAt: Date?
        var pinnedMachine: String?
        var failureCause: String?
        var jobs: [JobView]
        var url: String
        /// Which fields the build wrote, and that they are data (security review M4).
        var untrusted = Untrusted.buildFields
    }

    struct BuildRow: Encodable {
        var id: UUID
        var app: String
        var workflow: String
        var ref: String
        var commit: String
        var buildNumber: Int
        var status: BuildStatus
        var createdAt: Date
        var finishedAt: Date?
        var jobs: [String]
    }

    struct MachineView: Encodable {
        var id: UUID
        var name: String
        var online: Bool
        /// Builds are turned off on this Mac: it takes no new jobs (the owner resumes it on the Machines page).
        var paused: Bool
        var runningJobs: Int
        var maxConcurrentJobs: Int
        var lastSeenAt: Date?
        var macOS: String?
        var chip: String?
        var xcodes: [String]?
        var freeDiskGB: Double?
        var simulatorRuntimes: [String]?
        var tools: [String]?
        var canSignWithoutPrompt: Bool?
        var xcodeAccountSignedIn: Bool?
        var signingIdentities: [String]?
        /// Present when every job on this Mac runs in a VM: its slots, network filter, VM storage and images (the
        /// Xcode versions and simulator runtimes a job there gets). `problem` says why no slot is ready.
        var vm: VMReport?
    }

    static func page(_ server: URL, _ path: String) -> String {
        var root = server.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        return "\(root)/\(path)"
    }

    /// "Archive – iOS · Legilo".
    static func label(_ action: WorkflowAction) -> String { "\(action.kindLabel) · \(action.scheme)" }

    static func job(_ job: Job, machines: [UUID: String], excerpt: [String]? = nil) -> JobView {
        JobView(
            id: job.id, action: label(job.action), status: job.status, machine: job.machineID.flatMap { machines[$0] },
            currentStep: job.steps.first { $0.status == .running }?.name,
            failedStep: job.steps.first { $0.status == .failed }?.name,
            steps: job.steps.map { "\($0.name): \($0.status.rawValue)" }, queueNote: job.queueNote,
            failureReason: job.failureReason, tests: TestOutputs(job.outputs), notarization: Notarization(job.outputs),
            startedAt: job.startedAt,
            finishedAt: job.finishedAt, logExcerpt: excerpt)
    }

    static func build(
        _ build: Build, appSlug: String?, machines: [UUID: String], excerpts: [UUID: [String]], server: URL
    ) -> BuildView {
        let failed = build.jobs.filter { $0.status == .failed }
        let cause = failed.isEmpty ? nil : failed.map { job in
            let step = job.steps.first { $0.status == .failed }?.name
            return "\(label(job.action)) failed" + (step.map { " at \($0)" } ?? "")
                + (job.failureReason.map { ": \($0)" } ?? "")
        }.joined(separator: "; ")
        return BuildView(
            id: build.id, app: appSlug ?? build.appID.uuidString, workflow: build.workflow, ref: build.ref,
            commit: build.commit, buildNumber: build.buildNumber, status: build.status,
            finished: build.status != .queued && build.status != .running, createdAt: build.createdAt,
            finishedAt: build.finishedAt, pinnedMachine: build.pinnedMachineID.flatMap { machines[$0] },
            failureCause: cause,
            jobs: build.jobs.map { job($0, machines: machines, excerpt: excerpts[$0.id]) },
            url: page(server, "builds/\(build.id.uuidString)"))
    }

    static func row(_ build: Build, appSlug: String?) -> BuildRow {
        BuildRow(
            id: build.id, app: appSlug ?? build.appID.uuidString, workflow: build.workflow, ref: build.ref,
            commit: String(build.commit.prefix(7)), buildNumber: build.buildNumber, status: build.status,
            createdAt: build.createdAt, finishedAt: build.finishedAt,
            jobs: build.jobs.map { "\(label($0.action)): \($0.status.rawValue)" })
    }

    static func machine(_ machine: Machine, now: Date) -> MachineView {
        let report = machine.report
        return MachineView(
            id: machine.id, name: machine.name, online: machine.isOnline(now: now), paused: machine.paused,
            runningJobs: report?.runningJobIDs.count ?? 0, maxConcurrentJobs: machine.maxConcurrentJobs,
            lastSeenAt: machine.lastSeenAt, macOS: report?.macOSVersion, chip: report?.chip,
            xcodes: report?.xcodes.map { "\($0.version) (\($0.build))" }, freeDiskGB: report?.freeDiskGB,
            simulatorRuntimes: report?.simulatorRuntimes, tools: report.map { $0.tools.keys.sorted() },
            canSignWithoutPrompt: report?.canSignWithoutPrompt, xcodeAccountSignedIn: report?.xcodeAccountSignedIn,
            signingIdentities: report?.signingIdentities, vm: report?.vm)
    }
}
