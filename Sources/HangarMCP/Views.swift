import Foundation
import HangarCore

/// The shapes tools return: what an agent needs to decide its next step, not every stored field.
enum Views {
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

    struct TestSummary: Encodable {
        var passed: Int?
        var failed: Int?
        var skipped: Int?
        var total: Int?
        var failures: [TestFailure]?
    }

    struct TestFailure: Codable {
        var name: String
        var message: String
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
        var tests: TestSummary?
        var startedAt: Date?
        var finishedAt: Date?
        /// The last lines of the failed step's log, for a failed job.
        var logExcerpt: [String]?
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
        /// Runs without a login: signs with its CI keychain, needs a team App Store Connect key.
        var headless: Bool?
        var keychainProblem: String?
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

    static func tests(_ outputs: [String: String]) -> TestSummary? {
        guard outputs.keys.contains(where: { $0.hasPrefix("test.") }) else { return nil }
        let failures = outputs["test.failures"].flatMap {
            try? JSONDecoder().decode([TestFailure].self, from: Data($0.utf8))
        }
        return TestSummary(
            passed: outputs["test.passed"].flatMap(Int.init), failed: outputs["test.failed"].flatMap(Int.init),
            skipped: outputs["test.skipped"].flatMap(Int.init), total: outputs["test.total"].flatMap(Int.init),
            failures: failures)
    }

    static func job(_ job: Job, machines: [UUID: String], excerpt: [String]? = nil) -> JobView {
        JobView(
            id: job.id, action: label(job.action), status: job.status, machine: job.machineID.flatMap { machines[$0] },
            currentStep: job.steps.first { $0.status == .running }?.name,
            failedStep: job.steps.first { $0.status == .failed }?.name,
            steps: job.steps.map { "\($0.name): \($0.status.rawValue)" }, queueNote: job.queueNote,
            failureReason: job.failureReason, tests: tests(job.outputs), startedAt: job.startedAt,
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
            signingIdentities: report?.signingIdentities, headless: report?.headless,
            keychainProblem: report?.keychainProblem, vm: report?.vm)
    }
}
