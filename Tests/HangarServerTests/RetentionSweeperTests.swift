import Foundation
import HangarCore
import Testing

@testable import HangarServer

@Suite struct RetentionSweeperTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sweep-\(UUID().uuidString)")
    let builds: BuildRepository
    let app: App

    init() throws {
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        builds = BuildRepository(database: database)
        app = try AppRepository(database: database).create(
            CreateAppRequest(name: "Legilo", repoURL: "https://github.com/acme/legilo.git", appStoreConnectAppID: "42"))
    }

    /// A one-job build created 60 days ago; returns the job ID after creating its directory.
    func makeBuild(status: BuildStatus, finishedDaysAgo: Double?) throws -> (build: UUID, job: UUID) {
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
        let job = Job(
            id: UUID(), buildID: buildID, action: ArchiveAction(scheme: "Legilo", platform: .iOS, export: .appStoreConnect),
            status: jobStatus, createdAt: created, finishedAt: finished)
        let build = Build(
            id: buildID, appID: app.id, workflow: "testflight", ref: "main", commit: "abc", buildNumber: Int.random(in: 1...999_999),
            status: status, createdAt: created, finishedAt: finished, jobs: [job])
        try builds.insert(build, workflow: Workflow(project: "Legilo.xcodeproj", xcode: "27.2", actions: [job.action]))
        try makeDirectory(job.id.uuidString, modified: created)
        return (buildID, job.id)
    }

    func makeDirectory(_ name: String, modified: Date) throws {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: url.appendingPathComponent("log.jsonl"))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }

    @Test func deletesOnlyExpiredJobDirectories() async throws {
        let expired = try makeBuild(status: .succeeded, finishedDaysAgo: 31)
        let recent = try makeBuild(status: .failed, finishedDaysAgo: 29)
        // Status is what counts: an old running build keeps its logs whatever its timestamps say.
        let running = try makeBuild(status: .running, finishedDaysAgo: 45)
        let oldOrphan = UUID().uuidString
        let newOrphan = UUID().uuidString
        try makeDirectory(oldOrphan, modified: Self.now.addingTimeInterval(-31 * Self.day))
        try makeDirectory(newOrphan, modified: Self.now.addingTimeInterval(-1 * Self.day))
        try makeDirectory("notes", modified: Self.now.addingTimeInterval(-90 * Self.day))

        let sweeper = RetentionSweeper(jobsDirectory: directory, builds: builds, retentionDays: 30)
        try sweeper.sweep(now: Self.now)

        #expect(!exists(expired.job.uuidString))
        #expect(exists(recent.job.uuidString))
        #expect(exists(running.job.uuidString))
        #expect(!exists(oldOrphan))
        #expect(exists(newOrphan))
        #expect(exists("notes"))
        #expect(try builds.build(id: expired.build) != nil)
        #expect(try builds.job(id: expired.job) != nil)
    }

    @Test func missingJobsDirectoryIsNotAnError() throws {
        try RetentionSweeper(jobsDirectory: directory, builds: builds, retentionDays: 30).sweep(now: Self.now)
    }
}
