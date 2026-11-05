import Foundation
import HangarAppStoreConnect
import HangarCore
import Testing

@testable import HangarServer

private struct FakeSource: KnownNumberSource {
    var name: String
    var result: Result<Int?, any Error>
    init(_ name: String, _ number: Int?) { self.name = name; result = .success(number) }
    init(_ name: String, failing error: any Error) { self.name = name; result = .failure(error) }
    func highestNumber(for app: App) async throws -> Int? { try result.get() }
}

private struct Unreachable: Error {}

/// Scripted App Store Connect client; the unused calls are never made by the number sources.
private struct FakeASC: AppStoreConnectClient {
    var buildVersions: [String] = []
    var runs: [Int] = []
    func builds(appID: String, version: String?) async throws -> [ASCBuild] {
        buildVersions.map { ASCBuild(id: $0, version: $0, processingState: "VALID", platform: "IOS", uploadedDate: nil) }
    }
    func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { runs }
    func apps() async throws -> [ASCApp] { [] }
    func appIconURL(appID: String) async throws -> String? { nil }
    func betaGroups(appID: String) async throws -> [ASCBetaGroup] { [] }
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {}
    func setWhatToTest(buildID: String, locale: String, text: String) async throws {}
    func submitForBetaReview(buildID: String) async throws {}
}

@Suite struct BuildNumberServiceTests {
    func makeService(
        path: String = ":memory:", sources: [any KnownNumberSource]
    ) throws -> (BuildNumberService, BuildRepository, App) {
        let database = try HangarServer.Database(path: path)
        try database.migrate()
        let repository = BuildRepository(database: database)
        let app = try AppRepository(database: database).create(
            CreateAppRequest(name: "Demo", repoURL: "https://example.com/r.git", appStoreConnectAppID: "1"))
        return (BuildNumberService(repository: repository, sources: { sources }), repository, app)
    }

    static let workflow = Workflow(
        project: "App.xcodeproj", xcode: "27.2",
        actions: [WorkflowAction(scheme: "App", platform: .iOS, export: .appStoreConnect)])

    static let standard: [any KnownNumberSource] = [
        FakeSource("app-store-connect", 300), FakeSource("xcode-cloud", 305), FakeSource("appcast", nil),
    ]

    @Test func nextIsMaxOfAllSourcesPlusOne() async throws {
        let (service, repository, app) = try makeService(sources: Self.standard)
        try repository.setHighestAssigned(appID: app.id, 299)
        let report = try await service.preview(app: app)
        #expect(report.next == 306)
        #expect(report.highestHangar == 299)
        #expect(report.highestAppStoreConnect == 300)
        #expect(report.lastXcodeCloudRun == 305)
        #expect(!report.inFlight)
        #expect(try await service.reserve(app: app, buildID: UUID()) == 306)
        #expect(try repository.highestAssigned(appID: app.id) == 306)
    }

    @Test func remoteLowerThanLocalKeepsLocal() async throws {
        let (service, repository, app) = try makeService(sources: Self.standard)
        try repository.setHighestAssigned(appID: app.id, 400)
        #expect(try await service.preview(app: app).next == 401)
        #expect(try await service.reserve(app: app, buildID: UUID()) == 401)
    }

    @Test func noKnownNumbersStartsAtOne() async throws {
        let (service, _, app) = try makeService(sources: [FakeSource("appcast", nil)])
        #expect(try await service.reserve(app: app, buildID: UUID()) == 1)
    }

    @Test func failedBuildBurnsNumber() async throws {
        let (service, repository, app) = try makeService(sources: Self.standard)
        let buildID = UUID()
        let number = try await service.reserve(app: app, buildID: buildID)
        #expect(number == 306)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let jobID = UUID()
        try repository.insert(
            Build(
                id: buildID, appID: app.id, workflow: "release", ref: "main", commit: "abc", buildNumber: number,
                status: .queued, createdAt: now,
                jobs: [
                    Job(
                        id: jobID, buildID: buildID,
                        action: WorkflowAction(scheme: "App", platform: .iOS, export: .appStoreConnect),
                        status: .queued, createdAt: now)
                ]),
            workflow: Self.workflow)
        try repository.setJobStatus(id: jobID, status: .failed, at: now, failureReason: "boom")
        try repository.refreshBuildStatus(buildID: buildID)
        #expect(try repository.build(id: buildID)?.status == .failed)
        #expect(try await service.reserve(app: app, buildID: UUID()) == 307)
    }

    @Test(arguments: [":memory:", "file"])
    func concurrentReservationsAreDistinctAndIncreasing(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = kind == ":memory:" ? kind : directory.appendingPathComponent("hangar.sqlite").path
        let (service, repository, app) = try makeService(path: path, sources: Self.standard)
        let start = try await service.preview(app: app).next - 1
        let numbers = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<50 { group.addTask { try await service.reserve(app: app, buildID: UUID()) } }
            var all: [Int] = []
            for try await number in group { all.append(number) }
            return all
        }
        #expect(numbers.sorted() == Array((start + 1)...(start + 50)))
        #expect(try repository.highestAssigned(appID: app.id) == start + 50)
    }

    @Test func nonIntegerVersionIsAnError() async throws {
        let asc = FakeASC(buildVersions: ["300", "1.2.3"])
        let (service, repository, app) = try makeService(sources: [AppStoreConnectBuildsSource(client: asc)])
        let expected = BuildNumberError.nonInteger(source: "app-store-connect", value: "1.2.3")
        await #expect(throws: expected) { try await service.reserve(app: app, buildID: UUID()) }
        await #expect(throws: expected) { try await service.preview(app: app) }
        #expect(try repository.highestAssigned(appID: app.id) == nil)
    }

    @Test func unreachableSourceReservesNothing() async throws {
        let (service, repository, app) = try makeService(sources: [
            FakeSource("app-store-connect", 300), FakeSource("xcode-cloud", failing: Unreachable()),
        ])
        await #expect(throws: BuildNumberError.sourceUnavailable(source: "xcode-cloud", reason: "Unreachable()")) {
            try await service.reserve(app: app, buildID: UUID())
        }
        #expect(try repository.highestAssigned(appID: app.id) == nil)
    }

    @Test func sourcesClosureErrorPassesThrough() async throws {
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        let app = try AppRepository(database: database).create(
            CreateAppRequest(name: "Demo", repoURL: "https://example.com/r.git", appStoreConnectAppID: "1"))
        let service = BuildNumberService(
            repository: BuildRepository(database: database), sources: { throw BuildNumberError.appStoreConnectNotConfigured })
        await #expect(throws: BuildNumberError.appStoreConnectNotConfigured) {
            try await service.reserve(app: app, buildID: UUID())
        }
    }

    @Test func bumpNeverDecreases() async throws {
        let (service, repository, app) = try makeService(sources: Self.standard)
        try repository.setHighestAssigned(appID: app.id, 299)
        await #expect(throws: BuildNumberError.bumpNotHigher(current: 306, requested: 306)) {
            try await service.bump(app: app, to: 306)
        }
        await #expect(throws: BuildNumberError.bumpNotHigher(current: 306, requested: 10)) {
            try await service.bump(app: app, to: 10)
        }
        #expect(try repository.highestAssigned(appID: app.id) == 299)
        let report = try await service.bump(app: app, to: 400)
        #expect(report.next == 400)
        #expect(report.highestHangar == 399)
        #expect(try await service.reserve(app: app, buildID: UUID()) == 400)
    }

    @Test func previewReportsInFlight() async throws {
        let (service, repository, app) = try makeService(sources: Self.standard)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = UUID()
        try repository.insert(
            Build(
                id: id, appID: app.id, workflow: "release", ref: "main", commit: "abc", buildNumber: 306,
                status: .queued, createdAt: now, jobs: []),
            workflow: Self.workflow)
        #expect(try await service.preview(app: app).inFlight)
    }

    @Test func realSourcesReadFakeClient() async throws {
        let asc = FakeASC(buildVersions: ["12", "300", "7"], runs: [4, 305, 20])
        let app = App(id: UUID(), slug: "d", name: "D", repoURL: "x", appStoreConnectAppID: "1", createdAt: Date())
        #expect(try await AppStoreConnectBuildsSource(client: asc).highestNumber(for: app) == 300)
        #expect(try await XcodeCloudRunsSource(client: asc).highestNumber(for: app) == 305)
        #expect(try await AppcastSource().highestNumber(for: app) == nil)
        #expect(AppcastSource().name == "appcast")
        #expect(try await AppStoreConnectBuildsSource(client: FakeASC()).highestNumber(for: app) == nil)
    }
}
