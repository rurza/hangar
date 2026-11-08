import CryptoKit
import Foundation
import HangarCore
import Synchronization
import Testing

@testable import HangarServer

private let legilo = """
    version: 1
    workflows:
      testflight:
        project: Legilo.xcodeproj
        xcode: "27.2"
        team: YL78V8PY6H
        tools: [brew]
        actions:
          - { scheme: Legilo, platform: macos, export: app-store-connect }
          - { scheme: LegiloMobile, platform: ios, export: app-store-connect }
        post-actions:
          - testflight:
              groups: [Internal]
      beta:
        project: Legilo.xcodeproj
        xcode: "27.2"
        actions:
          - { scheme: Legilo, platform: macos, export: developer-id }
      ci:
        project: Legilo.xcodeproj
        xcode: "27.2"
        actions:
          - test: { scheme: LegiloTests, platform: ios, destination: "iPhone 17 Pro" }
          - archive: { scheme: Legilo, platform: macos, export: app-store-connect }
    """

private struct FixedSource: KnownNumberSource {
    var name = "app-store-connect"
    func highestNumber(for app: App) async throws -> Int? { 305 }
}

/// Scripted source host; records the token of every call.
final class FakeSourceHost: SourceHost {
    struct State {
        var commit = "0123456789abcdef0123456789abcdef01234567"
        var files: [String: String] = [WorkflowFile.path: legilo]
        var unknownRefs: Set<String> = []
        var tokens: [String?] = []
        var refs: [String] = []
        var repoURLs: [String] = []
        var tree = RepositoryTree(paths: [])
        var data: [String: Data] = [:]
        var reads: [String] = []
        var treeReads = 0
        var treeError: SourceHostError?
        /// Each call waits this long first (real time), to test timeouts.
        var delay: Duration = .zero
        var branches = RepositoryBranches(defaultBranch: "main", branches: ["main"])
        var branchesError: SourceHostError?
        var branchReads = 0
        var tags: [String] = []
        /// What `resolveBranchOrTag` was asked for.
        var branchOrTagNames: [String] = []
    }
    let state = Mutex(State())

    func resolveCommit(repoURL: String, ref: String, token: String?) async throws -> String {
        try state.withLock { state in
            state.tokens.append(token)
            state.refs.append(ref)
            state.repoURLs.append(repoURL)
            if state.unknownRefs.contains(ref) { throw SourceHostError.refNotFound(ref) }
            return state.commit
        }
    }

    /// Only `branches.branches` and `tags` resolve, as GitHub's `heads/` and `tags/` namespaces do.
    func resolveBranchOrTag(repoURL: String, name: String, token: String?) async throws -> String {
        try state.withLock { state in
            state.branchOrTagNames.append(name)
            guard state.branches.branches.contains(name) || state.tags.contains(name) else {
                throw SourceHostError.refNotFound(name)
            }
            return state.commit
        }
    }

    func readFile(repoURL: String, commit: String, path: String, token: String?) async throws -> String? {
        try await readData(repoURL: repoURL, commit: commit, path: path, token: token).map { String(decoding: $0, as: UTF8.self) }
    }

    func readData(repoURL: String, commit: String, path: String, token: String?, maxBytes: Int?) async throws -> Data? {
        let delay = state.withLock { $0.delay }
        if delay > .zero { try await Task.sleep(for: delay) }
        let data = state.withLock { state in
            state.tokens.append(token)
            state.reads.append(path)
            return state.data[path] ?? state.files[path].map { Data($0.utf8) }
        }
        if let maxBytes, let data, data.count > maxBytes { throw SourceHostError.tooLarge(path: path, bytes: data.count) }
        return data
    }

    func branches(repoURL: String, token: String?) async throws -> RepositoryBranches {
        try state.withLock { state in
            state.tokens.append(token)
            state.branchReads += 1
            if let error = state.branchesError { throw error }
            return state.branches  // as the host lists them; the server puts the default branch first
        }
    }

    func tree(repoURL: String, commit: String, token: String?) async throws -> RepositoryTree {
        let delay = state.withLock { $0.delay }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try state.withLock { state in
            state.tokens.append(token)
            state.treeReads += 1
            if let error = state.treeError { throw error }
            return state.tree
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct BuildServiceTests {
    let host = FakeSourceHost()
    let builds: BuildRepository
    let machines: MachineRepository
    let variables: VariableRepository
    let workflowFiles: WorkflowFileRepository
    let cancelRequests = CancelRequests()
    let events = EventBus()
    let app: App
    let service: BuildService

    init() throws {
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        builds = BuildRepository(database: database)
        machines = MachineRepository(database: database)
        variables = VariableRepository(database: database, box: SecretBox(key: SymmetricKey(size: .bits256)))
        let apps = AppRepository(database: database)
        app = try apps.create(
            CreateAppRequest(name: "Legilo", repoURL: "https://github.com/acme/legilo.git", appStoreConnectAppID: "42"))
        let numbers = BuildNumberService(repository: builds, sources: { [FixedSource()] })
        let scheduler = SchedulerLoop(builds: builds, machines: machines, events: events)
        workflowFiles = WorkflowFileRepository(database: database)
        service = BuildService(
            apps: apps, builds: builds, machines: machines, variables: variables, workflowFiles: workflowFiles,
            numbers: numbers, sourceHost: host,
            events: events, scheduler: scheduler, cancelRequests: cancelRequests)
    }

    func request(workflow: String = "testflight", ref: String = "main", machine: String? = nil) -> DeployRequest {
        DeployRequest(app: "legilo", workflow: workflow, ref: ref, machine: machine)
    }

    @Test func deployCreatesOneJobPerActionSharingTheNumber() async throws {
        let build = try await service.deploy(request())
        #expect(build.buildNumber == 306)
        #expect(build.status == .queued)
        #expect(build.workflow == "testflight")
        #expect(build.jobs.map(\.action.scheme) == ["Legilo", "LegiloMobile"])
        #expect(build.jobs.allSatisfy { $0.status == .queued && $0.steps.isEmpty && $0.buildID == build.id })
        #expect(try builds.build(id: build.id) == build)
        #expect(try builds.workflow(buildID: build.id)?.postActions.map(\.name) == ["testflight"])
        #expect(try builds.highestAssigned(appID: app.id) == 306)
    }

    @Test func deployCreatesTestAndArchiveJobsWithTheirKind() async throws {
        let build = try await service.deploy(request(workflow: "ci"))
        #expect(build.jobs.map(\.action) == [
            .test(scheme: "LegiloTests", platform: .iOS, destination: "iPhone 17 Pro"),
            WorkflowAction(scheme: "Legilo", platform: .macOS, export: .appStoreConnect),
        ])
        #expect(try builds.build(id: build.id)?.jobs.map(\.action.kind) == [.test, .archive])
    }

    @Test func deployPublishesTheBuildOnce() async throws {
        var iterator = events.subscribe().makeAsyncIterator()
        let build = try await service.deploy(request())
        guard case .server(.build(let published))? = await iterator.next() else {
            Issue.record("expected a build event")
            return
        }
        #expect(published == build)
    }

    @Test func deployPinsCommitSHA() async throws {
        let build = try await service.deploy(request(ref: "main"))
        #expect(build.commit == "0123456789abcdef0123456789abcdef01234567")
        #expect(build.ref == "main")
    }

    @Test func deployPinsTheNamedMachine() async throws {
        let (machine, _) = try machines.create(name: "studio")
        let build = try await service.deploy(request(machine: "studio"))
        #expect(build.pinnedMachineID == machine.id)
    }

    @Test func unknownMachineReservesNothing() async throws {
        await #expect(throws: DeployError.machineNotFound("ghost")) { _ = try await service.deploy(request(machine: "ghost")) }
        #expect(try builds.highestAssigned(appID: app.id) == nil)
    }

    @Test func unknownAppIsRejected() async throws {
        await #expect(throws: DeployError.appNotFound("nope")) {
            _ = try await service.deploy(DeployRequest(app: "nope", workflow: "testflight", ref: "main"))
        }
    }

    @Test func unknownRefIsRejected() async throws {
        host.state.withLock { $0.unknownRefs = ["ghost"] }
        await #expect(throws: DeployError.refNotFound("ghost")) { _ = try await service.deploy(request(ref: "ghost")) }
        #expect(try builds.highestAssigned(appID: app.id) == nil)
    }

    @Test func invalidWorkflowFileReservesNothing() async throws {
        host.state.withLock {
            $0.files[WorkflowFile.path] = """
                version: 1
                workflows:
                  testflight:
                    project: A.xcodeproj
                    xcode: "27.2"
                    actions:
                      - { scheme: A, platform: android, export: app-store-connect }
                """
        }
        await #expect(throws: DeployError.workflowFile(.unknownPlatform("android"))) { _ = try await service.deploy(request()) }
        #expect(try builds.highestAssigned(appID: app.id) == nil)
        #expect(try builds.builds(appID: app.id, limit: 10).isEmpty)
    }

    /// BatFi 263 spent its number on a Test job that could only fail: scheme BatFi has no tests.
    @Test func aTestActionOnASchemeWithoutTestsReservesNothing() async throws {
        let scheme = "Legilo.xcodeproj/xcshareddata/xcschemes/LegiloTests.xcscheme"
        host.state.withLock {
            $0.tree = RepositoryTree(paths: [scheme])
            $0.files[scheme] = #"<Scheme><TestAction shouldAutocreateTestPlan = "YES"></TestAction></Scheme>"#
        }
        do {
            _ = try await service.deploy(request(workflow: "ci"))
            Issue.record("the deploy went through")
        } catch DeployError.workflowCannotRun(let problems) {
            #expect(problems.count == 1)
            #expect(problems.first?.contains("“LegiloTests” has no tests") == true)
        }
        #expect(try builds.highestAssigned(appID: app.id) == nil)

        // With tests in the scheme, the deploy goes ahead (the cached verdict is per commit).
        host.state.withLock {
            $0.commit = "fedcba9876543210fedcba9876543210fedcba98"
            $0.files[scheme] = #"<Scheme><TestAction><Testables><TestableReference skipped = "NO"></TestableReference></Testables></TestAction></Scheme>"#
        }
        _ = try await service.deploy(request(workflow: "ci"))
    }

    @Test func aSchemeTheRepositoryHasNoFileForIsNotJudged() async throws {
        host.state.withLock { $0.tree = RepositoryTree(paths: ["Legilo.xcodeproj/project.pbxproj"]) }
        _ = try await service.deploy(request(workflow: "ci"))
        host.state.withLock { $0.treeError = .http(status: 500, body: "") }
        _ = try await service.deploy(request(workflow: "ci"))
    }

    @Test func missingWorkflowFileIsExplicit() async throws {
        host.state.withLock { $0.files = [:] }
        let commit = host.state.withLock { $0.commit }
        await #expect(throws: DeployError.workflowFileMissing(commit: commit)) { _ = try await service.deploy(request()) }
        #expect(try builds.highestAssigned(appID: app.id) == nil)
    }

    @Test func unknownWorkflowListsAvailable() async throws {
        await #expect(throws: DeployError.workflowNotFound(name: "nightly", available: ["beta", "ci", "testflight"])) {
            _ = try await service.deploy(request(workflow: "nightly"))
        }
        #expect(try builds.highestAssigned(appID: app.id) == nil)
    }

    @Test func approvalGateRejectedInPhase1() async throws {
        host.state.withLock {
            $0.files[WorkflowFile.path] = """
                version: 1
                workflows:
                  testflight:
                    project: A.xcodeproj
                    xcode: "27.2"
                    actions:
                      - { scheme: A, platform: ios, export: app-store-connect }
                    post-actions:
                      - testflight:
                          requires-approval: true
                """
        }
        await #expect(throws: DeployError.approvalNotSupported(postAction: "testflight")) { _ = try await service.deploy(request()) }
        #expect(try builds.highestAssigned(appID: app.id) == nil)
    }

    @Test func numberingFailureIsWrapped() async throws {
        struct Down: KnownNumberSource {
            var name = "app-store-connect"
            func highestNumber(for app: App) async throws -> Int? { throw BuildNumberError.appStoreConnectNotConfigured }
        }
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        let repo = BuildRepository(database: database)
        let apps = AppRepository(database: database)
        _ = try apps.create(CreateAppRequest(name: "Legilo", repoURL: "https://github.com/acme/legilo", appStoreConnectAppID: "42"))
        let machines = MachineRepository(database: database)
        let failing = BuildService(
            apps: apps, builds: repo, machines: machines,
            variables: VariableRepository(database: database, box: SecretBox(key: SymmetricKey(size: .bits256))),
            workflowFiles: WorkflowFileRepository(database: database),
            numbers: BuildNumberService(repository: repo, sources: { [Down()] }), sourceHost: host, events: events,
            scheduler: SchedulerLoop(builds: repo, machines: machines, events: events), cancelRequests: CancelRequests())
        await #expect(throws: DeployError.numbering(.appStoreConnectNotConfigured)) { _ = try await failing.deploy(request()) }
    }

    @Test func usesTheResolvedGitHubToken() async throws {
        try variables.set(scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "global", isSecret: true))
        try variables.set(scope: .app(app.id), name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "app", isSecret: true))
        _ = try await service.deploy(request())
        #expect(host.state.withLock { $0.tokens } == ["app", "app"])
    }

    @Test func publicRepositoriesUseNoToken() async throws {
        _ = try await service.deploy(request())
        #expect(host.state.withLock { $0.tokens } == [nil, nil])
    }

    @Test func workflowsListsTheFileAtTheCommit() async throws {
        let result = try await service.workflows(app: app, ref: "main")
        #expect(result.commit == "0123456789abcdef0123456789abcdef01234567")
        #expect(result.file.workflows.keys.sorted() == ["beta", "ci", "testflight"])
    }

    @Test func repositoryFileUsedWhenNoneStored() async throws {
        let result = try await service.workflows(app: app, ref: "main")
        #expect(result.source == .repository)
    }

    @Test func storedWorkflowFileWinsOverRepository() async throws {
        try workflowFiles.set(
            appID: app.id,
            yaml: """
                version: 1
                workflows:
                  testflight:
                    project: Legilo.xcodeproj
                    xcode: "27.2"
                    actions:
                      - { scheme: Stored, platform: ios, export: app-store-connect }
                """)
        let result = try await service.workflows(app: app, ref: "main")
        #expect(result.source == .hangar)
        #expect(result.commit == "0123456789abcdef0123456789abcdef01234567")
        #expect(result.file.workflows.keys.sorted() == ["testflight"])
        let build = try await service.deploy(request())
        #expect(build.jobs.map(\.action.scheme) == ["Stored"])
        // The repository's file is not even read.
        host.state.withLock { $0.files = [:] }
        _ = try await service.deploy(request())
    }

    @Test func cancelQueuedBuild() async throws {
        let build = try await service.deploy(request())
        let cancelled = try await service.cancel(buildID: build.id)
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.finishedAt != nil)
        #expect(cancelled.jobs.allSatisfy { $0.status == .cancelled && $0.finishedAt != nil })
        #expect(cancelRequests.pending(for: build.jobs.map(\.id)).isEmpty)
    }

    @Test func cancelRequestsStopOfRunningJobsAndCancelsTheRest() async throws {
        let (machine, _) = try machines.create(name: "studio")
        let build = try await service.deploy(request())
        let running = build.jobs[0]
        let queued = build.jobs[1]
        #expect(try builds.assign(jobID: running.id, to: machine.id, at: Date()))
        try builds.setJobStatus(id: running.id, status: .running, at: Date())
        let result = try await service.cancel(buildID: build.id)
        #expect(result.jobs.first { $0.id == queued.id }?.status == .cancelled)
        #expect(result.jobs.first { $0.id == running.id }?.status == .running)
        #expect(result.status == .running)
        #expect(cancelRequests.pending(for: build.jobs.map(\.id)) == [running.id])
    }

    @Test func cancelEndsAnAssignedJobThatHasNotStarted() async throws {
        let (machine, _) = try machines.create(name: "studio")
        let build = try await service.deploy(request())
        let (assigned, running) = (build.jobs[0], build.jobs[1])
        #expect(try builds.assign(jobID: assigned.id, to: machine.id, at: Date()))
        #expect(try builds.assign(jobID: running.id, to: machine.id, at: Date()))
        try builds.setJobStatus(id: running.id, status: .running, at: Date())
        let updates = events.subscribe()

        let result = try await service.cancel(buildID: build.id)

        let job = try #require(result.jobs.first { $0.id == assigned.id })
        #expect(job.status == .cancelled)
        #expect(job.finishedAt != nil)
        // Only the running job goes through the heartbeat.
        #expect(cancelRequests.pending(for: build.jobs.map(\.id)) == [running.id])
        // The machine can no longer start it.
        #expect(!(try builds.transitionJob(id: assigned.id, from: [.assigned], to: .running, at: Date(), machineID: machine.id)))
        var published = false
        for await event in updates {
            if case .server(.job(let job)) = event, job.id == assigned.id, job.status == .cancelled { published = true }
            if case .server(.build) = event { break }
        }
        #expect(published)
    }

    @Test func cancellingATerminalBuildIsANoOp() async throws {
        let build = try await service.deploy(request())
        let first = try await service.cancel(buildID: build.id)
        let second = try await service.cancel(buildID: build.id)
        #expect(second == first)
    }

    @Test func cancellingAnUnknownBuildFails() async throws {
        let id = UUID()
        await #expect(throws: DeployError.buildNotFound(id)) { _ = try await service.cancel(buildID: id) }
    }

    @Test func cancelRequestsTracksPendingJobs() {
        let requests = CancelRequests()
        let (a, b, c) = (UUID(), UUID(), UUID())
        requests.request([a, b])
        #expect(Set(requests.pending(for: [b, c])) == [b])
        requests.clear(b)
        #expect(requests.pending(for: [a, b, c]) == [a])
    }
}
