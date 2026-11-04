import Foundation
import GRDB
import HangarCore
import Testing

@testable import HangarServer

@Suite struct BuildRepositoryTests {
    let database: HangarServer.Database
    let builds: BuildRepository
    let app: App

    init() throws {
        database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        builds = BuildRepository(database: database)
        app = try AppRepository(database: database).create(
            CreateAppRequest(name: "Demo", repoURL: "https://example.com/r.git", appStoreConnectAppID: "1"))
    }

    func makeBuild(number: Int = 1, jobCount: Int = 1) -> Build {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000.5)
        let jobs = (0..<jobCount).map { _ in
            Job(
                id: UUID(), buildID: id, action: ArchiveAction(scheme: "App", platform: .iOS, export: .appStoreConnect),
                status: .queued, createdAt: now)
        }
        return Build(
            id: id, appID: app.id, workflow: "release", ref: "main", commit: "abc", buildNumber: number,
            status: .queued, createdAt: now, jobs: jobs)
    }

    @Test func insertRoundTrips() throws {
        let build = makeBuild(jobCount: 2)
        try builds.insert(build)
        #expect(try builds.build(id: build.id) == build)
        #expect(try builds.builds(appID: app.id, limit: 10) == [build])
        #expect(try builds.builds(appID: nil, limit: 10) == [build])
        #expect(try builds.inFlight(appID: app.id))
        #expect(try builds.jobs(status: [.queued]).count == 2)
    }

    @Test func assignIsAtomic() throws {
        let build = makeBuild()
        try builds.insert(build)
        let job = build.jobs[0].id
        let first = try builds.assign(jobID: job, to: UUID(), at: Date())
        let second = try builds.assign(jobID: job, to: UUID(), at: Date())
        #expect([first, second].filter { $0 }.count == 1)
        #expect(try builds.job(id: job)?.status == .assigned)
        try builds.unassign(jobID: job)
        #expect(try builds.job(id: job)?.status == .queued)
        #expect(try builds.job(id: job)?.machineID == nil)
    }

    @Test func refreshBuildStatusDerives() throws {
        let build = makeBuild()
        try builds.insert(build)
        let job = build.jobs[0].id
        let start = Date(timeIntervalSince1970: 1_800_000_100)
        try builds.setJobStatus(id: job, status: .running, at: start)
        #expect(try builds.refreshBuildStatus(buildID: build.id).status == .running)
        #expect(try builds.build(id: build.id)?.finishedAt == nil)

        let end = Date(timeIntervalSince1970: 1_800_000_200)
        try builds.setJobStatus(id: job, status: .failed, at: end, failureReason: "boom")
        let refreshed = try builds.refreshBuildStatus(buildID: build.id)
        #expect(refreshed.status == .failed)
        #expect(refreshed.finishedAt == end)
        #expect(refreshed.jobs[0].failureReason == "boom")
        #expect(refreshed.jobs[0].startedAt == start)
        #expect(!(try builds.inFlight(appID: app.id)))
    }

    @Test func upsertStepKeepsOrderAndStampsTimes() throws {
        let build = makeBuild()
        try builds.insert(build)
        let job = build.jobs[0].id
        let t1 = Date(timeIntervalSince1970: 1_800_000_001)
        let t2 = Date(timeIntervalSince1970: 1_800_000_002)
        try builds.upsertStep(jobID: job, StepUpdate(name: "checkout", status: .running, at: t1))
        try builds.upsertStep(jobID: job, StepUpdate(name: "archive", status: .pending, at: t1))
        try builds.upsertStep(jobID: job, StepUpdate(name: "checkout", status: .succeeded, at: t2))
        #expect(try builds.job(id: job)?.steps == [
            StepRecord(name: "checkout", status: .succeeded, startedAt: t1, finishedAt: t2),
            StepRecord(name: "archive", status: .pending),
        ])
        try builds.setOutputs(jobID: job, ["ipa": "/x.ipa"])
        try builds.setQueueNote(jobID: job, note: "waiting")
        let loaded = try #require(try builds.job(id: job))
        #expect(loaded.outputs == ["ipa": "/x.ipa"])
        #expect(loaded.queueNote == "waiting")
    }

    @Test func duplicateReservedNumberThrows() throws {
        try builds.reserveNumber(appID: app.id, number: 5, buildID: UUID())
        #expect(throws: (any Error).self) { try builds.reserveNumber(appID: app.id, number: 5, buildID: UUID()) }
        try builds.reserveNumber(appID: app.id, number: 6, buildID: UUID())
    }

    @Test func counterAndTransactionVariants() throws {
        #expect(try builds.highestAssigned(appID: app.id) == nil)
        let build = makeBuild(number: 7)
        try builds.inTransaction { db in
            try BuildRepository.reserveNumber(db, appID: app.id, number: 7, buildID: build.id)
            try BuildRepository.setHighestAssigned(db, appID: app.id, 7)
            #expect(try BuildRepository.highestAssigned(db, appID: app.id) == 7)
        }
        try builds.setHighestAssigned(appID: app.id, 9)
        #expect(try builds.highestAssigned(appID: app.id) == 9)
    }
}
