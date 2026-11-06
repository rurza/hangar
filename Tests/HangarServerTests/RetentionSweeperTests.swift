import Foundation
import HangarCore
import Testing

@testable import HangarServer

@Suite struct RetentionSweeperTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sweep-\(UUID().uuidString)")
        .appendingPathComponent("jobs")
    let builds: BuildRepository
    let apps: AppRepository
    let app: App

    init() throws {
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        builds = BuildRepository(database: database)
        apps = AppRepository(database: database)
        app = try apps.create(
            CreateAppRequest(name: "Legilo", repoURL: "https://github.com/acme/legilo.git", appStoreConnectAppID: "42"))
    }

    /// A build of `app` created 60 days ago, with `jobs` jobs whose directories hold `megabytes` each.
    @discardableResult
    func makeBuild(
        _ app: App? = nil, status: BuildStatus, finishedDaysAgo: Double?, number: Int = Int.random(in: 1...999_999),
        jobs count: Int = 1, megabytes: Int = 0
    ) throws -> (build: UUID, jobs: [UUID]) {
        let app = app ?? self.app
        let created = Self.now.addingTimeInterval(-60 * Self.day)
        let finished = finishedDaysAgo.map { Self.now.addingTimeInterval(-$0 * Self.day) }
        let buildID = UUID()
        let jobStatus: JobStatus =
            switch status {
            case .queued: .queued
            case .running: .running
            case .succeeded: .succeeded
            case .failed: .failed
            case .cancelled: .cancelled
            }
        let action = WorkflowAction(scheme: "Legilo", platform: .iOS, export: .appStoreConnect)
        let jobs = (0..<count).map { _ in
            Job(id: UUID(), buildID: buildID, action: action, status: jobStatus, createdAt: created, finishedAt: finished)
        }
        let build = Build(
            id: buildID, appID: app.id, workflow: "testflight", ref: "main", commit: "abc", buildNumber: number,
            status: status, createdAt: created, finishedAt: finished, jobs: jobs)
        try builds.insert(build, workflow: Workflow(project: "Legilo.xcodeproj", xcode: "27.2", actions: [action]))
        for job in jobs { try makeDirectory(job.id.uuidString, modified: created, megabytes: megabytes) }
        return (buildID, jobs.map(\.id))
    }

    func makeDirectory(_ name: String, modified: Date, megabytes: Int = 0) throws {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("artifacts"), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: url.appendingPathComponent("log.jsonl"))
        if megabytes > 0 {
            try Data(repeating: 1, count: megabytes * 1_000_000).write(to: url.appendingPathComponent("artifacts/App.ipa"))
        }
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func exists(_ id: UUID) -> Bool { exists(id.uuidString) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }

    func sweeper(_ policy: RetentionPolicy) -> RetentionSweeper {
        RetentionSweeper(jobsDirectory: directory, builds: builds, policy: policy)
    }

    @Test func keepsEachAppsLatestBuildsAndRecentOnes() throws {
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        // Legilo: six old builds (the two oldest go), two jobs each; one this week.
        let old = try (1...6).map { try makeBuild(status: .succeeded, finishedDaysAgo: 40 - Double($0), number: $0, jobs: 2) }
        let recent = try makeBuild(status: .failed, finishedDaysAgo: 2, number: 7)
        // Another app's single old build is its latest: it stays.
        let other = try apps.create(
            CreateAppRequest(name: "BatFi", repoURL: "https://github.com/acme/batfi.git", appStoreConnectAppID: "43"))
        let lone = try makeBuild(other, status: .succeeded, finishedDaysAgo: 300)
        // Status is what counts: an old running or queued build keeps its files whatever its timestamps say.
        let running = try makeBuild(status: .running, finishedDaysAgo: 45)
        let queued = try makeBuild(status: .queued, finishedDaysAgo: nil)

        let removed = try sweeper(RetentionPolicy(keepBuildsPerApp: 5, keepDays: 7, maxGB: 100)).sweep(now: Self.now)

        #expect(Set(removed) == Set((old[0].jobs + old[1].jobs).map(\.uuidString)))
        #expect(old[2...].allSatisfy { $0.jobs.allSatisfy(exists) })
        #expect(exists(recent.jobs[0]) && exists(lone.jobs[0]) && exists(running.jobs[0]) && exists(queued.jobs[0]))
        // Build history stays.
        #expect(try builds.build(id: old[0].build) != nil)
        #expect(try builds.job(id: old[0].jobs[0]) != nil)
    }

    @Test func aDeletedAppsFilesGoAfterAnHour() throws {
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let oldOrphan = UUID().uuidString
        let newOrphan = UUID().uuidString
        try makeDirectory(oldOrphan, modified: Self.now.addingTimeInterval(-2 * 3600))
        try makeDirectory(newOrphan, modified: Self.now.addingTimeInterval(-60))
        try makeDirectory("notes", modified: Self.now.addingTimeInterval(-90 * Self.day))
        try sweeper(.standard).sweep(now: Self.now)
        #expect(!exists(oldOrphan))
        #expect(exists(newOrphan))
        #expect(exists("notes"))
    }

    @Test func theCapRemovesTheOldestBuildsFirstButNeverAnAppsLatestOrAnUnfinishedOne() throws {
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let oldest = try makeBuild(status: .succeeded, finishedDaysAgo: 5, number: 1, jobs: 2, megabytes: 3)
        let middle = try makeBuild(status: .failed, finishedDaysAgo: 3, number: 2, megabytes: 4)
        let latest = try makeBuild(status: .succeeded, finishedDaysAgo: 1, number: 3, megabytes: 5)
        let running = try makeBuild(status: .running, finishedDaysAgo: nil, megabytes: 6)
        // 6 + 4 + 5 + 6 MB under a 16 MB cap: the oldest build alone goes.
        let sweeper = sweeper(RetentionPolicy(keepBuildsPerApp: 5, keepDays: 7, maxGB: 0.016))
        try sweeper.sweep(now: Self.now)
        #expect(!exists(oldest.jobs[0]) && !exists(oldest.jobs[1]))
        #expect(exists(middle.jobs[0]) && exists(latest.jobs[0]) && exists(running.jobs[0]))
        // Under 1 MB: everything else but the app's latest build and the running one.
        try RetentionSweeper(jobsDirectory: directory, builds: builds, policy: RetentionPolicy(keepBuildsPerApp: 5, keepDays: 7, maxGB: 0.001))
            .sweep(now: Self.now)
        #expect(!exists(middle.jobs[0]))
        #expect(exists(latest.jobs[0]) && exists(running.jobs[0]))
    }

    @Test func measuresWhatTheServersFilesTake() throws {
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try makeBuild(status: .succeeded, finishedDaysAgo: 1, megabytes: 3)
        try Data(repeating: 2, count: 2_000_000).write(to: directory.deletingLastPathComponent().appendingPathComponent("hangar.sqlite"))
        let sweeper = sweeper(.standard)
        #expect(sweeper.usage == nil)
        try sweeper.sweep(now: Self.now)
        let usage = try #require(sweeper.usage)
        #expect(usage.totalGB > 0.0049 && usage.totalGB < 0.0052)
        #expect(usage.parts.map(\.label) == ["Build logs and artifacts", "Other"])
        #expect(usage.measuredAt == Self.now)
    }

    @Test func missingJobsDirectoryIsNotAnError() throws {
        try sweeper(.standard).sweep(now: Self.now)
    }

    @Test func theXcodesQueuedAndRunningJobsNeedAreListed() throws {
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try makeBuild(status: .queued, finishedDaysAgo: nil)
        try makeBuild(status: .running, finishedDaysAgo: nil)
        try makeBuild(status: .succeeded, finishedDaysAgo: 1)
        #expect(try builds.xcodesNeeded() == ["27.2"])
    }
}
