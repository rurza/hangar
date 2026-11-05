import Foundation
import HangarClient
import HangarCore
import Testing

@testable import hangar

@Suite(.timeLimit(.minutes(1))) struct CommandParsingTests {
    typealias H = CLIHarness

    @Test func deployDefaultsRefToMain() async throws {
        let parsed = try #require(try Hangar.parseAsRoot(["deploy", "legilo", "testflight"]) as? Deploy)
        #expect(parsed.ref == "main")

        let harness = H(responses: [try H.json(H.build(), status: 202)])
        let result = await harness.run(["deploy", "legilo", "testflight", "--no-wait"])
        #expect(result.exitCode == 0)
        #expect(try result.bodies(DeployRequest.self) == [DeployRequest(app: "legilo", workflow: "testflight", ref: "main")])
        #expect(result.out.contains("42"))
        #expect(result.out.contains(H.buildID.uuidString.lowercased()))
        #expect(result.out.contains("Legilo/ios"))
    }

    @Test func serverDefaultsToEnvironmentThenLocalhost() throws {
        #expect(GlobalOptions.resolveServer(nil, environment: [:]).absoluteString == "http://localhost:8787")
        #expect(
            GlobalOptions.resolveServer(nil, environment: ["HANGAR_SERVER": "http://mini:8787"]).absoluteString
                == "http://mini:8787")
        #expect(
            GlobalOptions.resolveServer("http://other:1", environment: ["HANGAR_SERVER": "http://mini:8787"])
                .absoluteString == "http://other:1")
    }

    @Test func workflowsSetSendsFileContents() async throws {
        let yaml = "version: 1\nworkflows: {}\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-\(UUID().uuidString).yml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let stored = StoredWorkflowFile(yaml: yaml, workflows: WorkflowFile(version: 1, workflows: [:]), updatedAt: H.t0)
        let harness = H(responses: [try H.json(stored)])
        let result = await harness.run(["workflows", "legilo", "--set", file.path])

        #expect(result.exitCode == 0)
        let request = try #require(result.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/v1/apps/legilo/workflow-file")
        #expect(try result.bodies(PutWorkflowFileRequest.self).map(\.yaml) == [yaml])
    }

    @Test func workflowsClearDeletesAndShowsSource() async throws {
        let cleared = await H(responses: [StubTransport.Response(status: 204)]).run(["workflows", "legilo", "--clear"])
        #expect(cleared.exitCode == 0)
        #expect(cleared.requests.first?.httpMethod == "DELETE")
        #expect(cleared.requests.first?.url?.path == "/api/v1/apps/legilo/workflow-file")

        let response = WorkflowsResponse(
            commit: "abc1234def5678", workflows: WorkflowFile(version: 1, workflows: [:]), source: .hangar)
        let shown = await H(responses: [try H.json(response)]).run(["workflows", "legilo"])
        #expect(shown.out.contains("Source: defined in Hangar"))
    }

    @Test func varSetReadsStdinWhenNoValue() async throws {
        let harness = H(responses: [StubTransport.Response(status: 204)], stdin: "s3cret-value\n")
        let result = await harness.run(["var", "set", "API_KEY", "--app", "legilo", "--secret"])

        #expect(result.exitCode == 0)
        let request = try #require(result.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/v1/apps/legilo/variables/API_KEY")
        #expect(try result.bodies(VariableInput.self) == [VariableInput(value: "s3cret-value", isSecret: true)])
        #expect(!result.out.contains("s3cret"))
        #expect(!result.err.contains("s3cret"))
    }

    @Test func varSetWithValueNeverEchoesIt() async throws {
        let harness = H(responses: [StubTransport.Response(status: 204)])
        let result = await harness.run(["var", "set", "API_KEY", "--secret", "--value", "s3cret-value"])

        #expect(result.exitCode == 0)
        #expect(result.requests.first?.url?.path == "/api/v1/variables/API_KEY")
        #expect(try result.bodies(VariableInput.self) == [VariableInput(value: "s3cret-value", isSecret: true)])
        #expect(!result.out.contains("s3cret"))
        #expect(!result.err.contains("s3cret"))
        #expect(result.err.contains("shell history"))
    }

    @Test func varSetForWorkflowsAndGroups() async throws {
        let app = await H(responses: [StubTransport.Response(status: 204)], stdin: "dsn\n")
            .run(["var", "set", "SENTRY_DSN", "--app", "legilo", "--workflow", "Beta", "--workflow", "Release"])
        #expect(app.exitCode == 0)
        #expect(try app.bodies(VariableInput.self) == [VariableInput(value: "dsn", workflows: ["Beta", "Release"])])
        #expect(app.out.contains("for legilo (Beta, Release)"))

        let group = await H(responses: [StubTransport.Response(status: 204)], stdin: "t\n")
            .run(["var", "set", "SENTRY_AUTH_TOKEN", "--group", "Sentry", "--secret"])
        #expect(group.requests.first?.url?.path == "/api/v1/variable-groups/Sentry/variables/SENTRY_AUTH_TOKEN")
        #expect(group.out.contains("in group Sentry"))

        let refused = await H().run(["var", "set", "X", "--workflow", "Beta", "--value", "v"])
        #expect(refused.exitCode == 64)
        #expect(refused.requests.isEmpty)
        let both = await H().run(["var", "set", "X", "--app", "a", "--group", "g", "--value", "v"])
        #expect(both.exitCode == 64)
    }

    @Test func varRemoveNamesTheRowByItsWorkflows() async throws {
        let result = await H(responses: [StubTransport.Response(status: 204)])
            .run(["var", "remove", "SENTRY_DSN", "--app", "legilo", "--workflow", "Beta"])
        #expect(result.exitCode == 0)
        let request = try #require(result.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/v1/apps/legilo/variables/SENTRY_DSN")
        #expect(request.url?.query == "workflow=Beta")
    }

    @Test func varListShowsWorkflowsLinksAndAWorkflowsEnvironment() async throws {
        let variables = [
            VariableSummary(scope: .app(UUID()), name: "SENTRY_DSN", isSecret: false, asFile: false, workflows: ["Beta"], updatedAt: H.t0),
        ]
        let links = [AppVariableGroupLink(groupID: UUID(), name: "Sentry", workflows: [], variables: [
            VariableSummary(scope: .group(UUID()), name: "SENTRY_AUTH_TOKEN", isSecret: true, asFile: false, updatedAt: H.t0),
        ])]
        let listed = await H(responses: [try H.json(variables), try H.json(links)]).run(["var", "list", "--app", "legilo"])
        #expect(listed.exitCode == 0)
        #expect(listed.out.contains("WORKFLOWS"))
        #expect(listed.out.contains("Beta"))
        #expect(listed.out.contains("Sentry (all workflows): SENTRY_AUTH_TOKEN"))

        let effective = [EffectiveVariable(
            name: "SENTRY_AUTH_TOKEN", isSecret: true, asFile: false, source: VariableSource(kind: .group, group: "Sentry"))]
        let environment = await H(responses: [try H.json(effective)]).run(["var", "list", "--app", "legilo", "--workflow", "Beta"])
        #expect(environment.requests.first?.url?.path == "/api/v1/apps/legilo/environment")
        #expect(environment.requests.first?.url?.query == "workflow=Beta")
        #expect(environment.out.contains("group Sentry"))
    }

    @Test func varGroupAndLinkCommands() async throws {
        let group = VariableGroup(id: UUID(), name: "Sentry", createdAt: H.t0)
        let created = await H(responses: [try H.json(group, status: 201)]).run(["var", "group", "create", "Sentry"])
        #expect(created.requests.first?.httpMethod == "POST")
        #expect(try created.bodies(VariableGroupRequest.self) == [VariableGroupRequest(name: "Sentry")])

        let linked = await H(responses: [StubTransport.Response(status: 204)])
            .run(["var", "link", "Sentry", "--app", "legilo", "--workflow", "Beta"])
        #expect(linked.requests.first?.httpMethod == "PUT")
        #expect(linked.requests.first?.url?.path == "/api/v1/apps/legilo/variable-groups/Sentry")
        #expect(try linked.bodies(LinkVariableGroupRequest.self) == [LinkVariableGroupRequest(workflows: ["Beta"])])

        let unlinked = await H(responses: [StubTransport.Response(status: 204)]).run(["var", "unlink", "Sentry", "--app", "legilo"])
        #expect(unlinked.requests.first?.httpMethod == "DELETE")

        let removed = await H(responses: [StubTransport.Response(status: 204)]).run(["var", "group", "remove", "Sentry"])
        #expect(removed.requests.first?.url?.path == "/api/v1/variable-groups/Sentry")
    }

    @Test func varSetReadsValueFileAndRejectsTwoSources() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-\(UUID().uuidString).txt")
        try "line one\nline two\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = await H(responses: [StubTransport.Response(status: 204)])
            .run(["var", "set", "NOTES", "--as-file", "--value-file", file.path])
        #expect(try result.bodies(VariableInput.self) == [VariableInput(value: "line one\nline two", asFile: true)])

        let usage = await H().run(["var", "set", "NOTES", "--value", "a", "--value-file", file.path])
        #expect(usage.exitCode == 64)
        #expect(usage.requests.isEmpty)
    }

    @Test func settingsAscKeyProducesThreeVariables() async throws {
        let p8 = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMG\n-----END PRIVATE KEY-----\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("AuthKey_\(UUID().uuidString).p8")
        try p8.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let harness = H(responses: Array(repeating: StubTransport.Response(status: 204), count: 3))
        let result = await harness.run(["settings", "asc-key", "--key-id", "ABC123", "--issuer-id", "issuer-uuid", "--p8", file.path])

        #expect(result.exitCode == 0)
        #expect(result.requests.allSatisfy { $0.httpMethod == "PUT" })
        #expect(result.requests.map { $0.url?.path } == [
            "/api/v1/variables/HANGAR_ASC_KEY_ID",
            "/api/v1/variables/HANGAR_ASC_ISSUER_ID",
            "/api/v1/variables/HANGAR_ASC_KEY_PATH",
        ])
        #expect(try result.bodies(VariableInput.self) == [
            VariableInput(value: "ABC123"),
            VariableInput(value: "issuer-uuid"),
            VariableInput(value: p8, isSecret: true, asFile: true),
        ])
        #expect(!result.out.contains("PRIVATE KEY"))
    }

    @Test func settingsAscKeyWithoutIssuerDeletesIssuer() async throws {
        let p8 = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMG\n-----END PRIVATE KEY-----\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("AuthKey_\(UUID().uuidString).p8")
        try p8.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let harness = H(responses: Array(repeating: StubTransport.Response(status: 204), count: 3))
        let result = await harness.run(["settings", "asc-key", "--key-id", "INDIVIDUAL1", "--p8", file.path])

        #expect(result.exitCode == 0)
        #expect(result.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "PUT /api/v1/variables/HANGAR_ASC_KEY_ID",
            "DELETE /api/v1/variables/HANGAR_ASC_ISSUER_ID",
            "PUT /api/v1/variables/HANGAR_ASC_KEY_PATH",
        ])
        #expect(try result.bodies(VariableInput.self) == [
            VariableInput(value: "INDIVIDUAL1"),
            VariableInput(value: p8, isSecret: true, asFile: true),
        ])
        #expect(!result.out.contains("PRIVATE KEY"))
    }

    @Test func settingsGitHubTokenReadsStdin() async throws {
        let harness = H(responses: [StubTransport.Response(status: 204)], stdin: "ghp_abc\n")
        let result = await harness.run(["settings", "github-token"])
        #expect(result.exitCode == 0)
        #expect(result.requests.first?.url?.path == "/api/v1/variables/HANGAR_GITHUB_TOKEN")
        #expect(try result.bodies(VariableInput.self) == [VariableInput(value: "ghp_abc", isSecret: true)])
        #expect(!result.out.contains("ghp_abc"))
    }

    @Test func serverErrorExitsOneWithMessage() async throws {
        let harness = H(responses: [try H.json(APIError(code: "app_exists", message: "An app named 'Legilo' exists"), status: 409)])
        let result = await harness.run(["apps", "add", "Legilo", "--repo", "https://github.com/acme/legilo", "--asc-app-id", "1"])
        #expect(result.exitCode == 1)
        #expect(result.err == "error: An app named 'Legilo' exists (app_exists)\n")
        #expect(result.out.isEmpty)
    }

    @Test func machinesAddPrintsTokenOnce() async throws {
        let machine = Machine(id: H.machineID, name: "mini", createdAt: H.t0)
        let harness = H(responses: [try H.json(CreateMachineResponse(machine: machine, token: "tok_0123456789"), status: 201)])
        let result = await harness.run(["machines", "add", "mini"])

        #expect(result.exitCode == 0)
        #expect(try result.bodies(CreateMachineRequest.self) == [CreateMachineRequest(name: "mini", maxConcurrentJobs: 1)])
        #expect(result.out.components(separatedBy: "tok_0123456789").count == 2)
        #expect(result.out.hasSuffix("Save this token now; it is not shown again.\n"))
    }

    @Test func machinesPauseAndResume() async throws {
        let running = MachineReport(
            macOSVersion: "26.1", xcodes: [], chip: "M4", performanceCores: 4, memoryGB: 16, freeDiskGB: 100,
            onACPower: true, tools: [:], canSignWithoutPrompt: true, runningJobIDs: [UUID()])
        let paused = Machine(id: H.machineID, name: "mini", report: running, createdAt: H.t0, paused: true)
        let pause = await H(responses: [try H.json(paused)]).run(["machines", "pause", "mini"])
        #expect(pause.exitCode == 0)
        #expect(pause.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == ["POST /api/v1/machines/mini/pause"])
        #expect(pause.out == """
            Paused mini: it takes no new builds; the job it is running finishes first.
            Turn builds back on with: hangar machines resume mini

            """)

        var resumed = paused
        resumed.paused = false
        let resume = await H(responses: [try H.json(resumed)]).run(["machines", "resume", "mini"])
        #expect(resume.exitCode == 0)
        #expect(resume.requests.map { $0.url?.path ?? "" } == ["/api/v1/machines/mini/resume"])
        #expect(resume.out == "Resumed mini: it takes builds again.\n")

        let missing = await H(responses: [try H.json(APIError(code: "machine_not_found", message: "No machine 'nope'."), status: 404)])
            .run(["machines", "pause", "nope"])
        #expect(missing.exitCode != 0)
        #expect(missing.err.contains("No machine 'nope'."))
    }

    @Test func machinesListShowsPaused() {
        let online = Machine(id: UUID(), name: "mini", lastSeenAt: H.t0, createdAt: H.t0, paused: true)
        let offline = Machine(id: UUID(), name: "studio", createdAt: H.t0)
        let text = Machines.List.render([online, offline], now: H.t0, timeZone: H.utc)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasPrefix("mini") && $0.contains("online, paused") })
        #expect(lines.contains { $0.hasPrefix("studio") && $0.contains("offline") && !$0.contains("paused") })
    }

    @Test func machinesListShowsAVMMacsSlotsAndImages() {
        func machine(_ name: String, slots: Int) -> Machine {
            Machine(
                id: UUID(), name: name, maxConcurrentJobs: 1, lastSeenAt: H.t0,
                report: MachineReport(
                    macOSVersion: "26.6", xcodes: [InstalledXcode(version: "26.1", build: "A", path: "/Applications/Xcode.app")],
                    chip: "M4", performanceCores: 10, memoryGB: 32, freeDiskGB: 300, onACPower: true, tools: [:],
                    canSignWithoutPrompt: true, runningJobIDs: [UUID()],
                    vm: VMReport(
                        slots: slots, configuredSlots: 2, freeSlots: max(slots - 1, 0), storageFreeGB: 120,
                        networkFilter: slots > 0, images: [VMImageInfo(name: "xcode-27.2", macOS: "26.6.2", xcode: "27.2")])),
                createdAt: H.t0)
        }
        let text = Machines.List.render([machine("mini", slots: 2), machine("studio", slots: 0)], now: H.t0, timeZone: H.utc)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasPrefix("mini") && $0.contains("online, VM ") && $0.contains("1/2") && $0.contains("27.2") && !$0.contains("26.1") })
        #expect(lines.contains { $0.hasPrefix("studio") && $0.contains("online, VM not ready") })
    }

    @Test func logsFallsBackFromJobToBuild() async throws {
        let entry = LogEntry(t: H.t0, step: "archive", line: "Compiling")
        let harness = H(responses: [
            try H.json(APIError(code: "job_not_found", message: "No job"), status: 404),
            try H.json(H.build(H.job(status: .running))),
            try H.json([entry]),
        ])
        let result = await harness.run(["logs", H.buildID.uuidString, "--tail", "5"])

        #expect(result.exitCode == 0)
        #expect(result.requests.map { $0.url?.path } == [
            "/api/v1/jobs/\(H.buildID.uuidString)",
            "/api/v1/builds/\(H.buildID.uuidString)",
            "/api/v1/jobs/\(H.jobID.uuidString)/log",
        ])
        #expect(result.out == "[Legilo] 08:00:00 [archive] Compiling\n")
    }

    @Test func logsCondenseXcodebuildUnlessRaw() async throws {
        let lines = [
            "Ld /x/Legilo.app/Legilo normal arm64 (in target 'Legilo' from project 'Legilo')",
            "    /usr/bin/clang -Xlinker -reproducible -o /x/Legilo.app/Legilo",
        ]
        let entries = lines.map { LogEntry(t: H.t0, step: "archive", line: $0) }
        let condensed = await H(responses: [try H.json(H.job(status: .failed)), try H.json(entries)])
            .run(["logs", H.jobID.uuidString])
        #expect(condensed.exitCode == 0)
        #expect(condensed.out == "08:00:00 [archive] ▸ Link Legilo (arm64)\n")

        // No full log kept: the stored lines as they are.
        let raw = await H(responses: [try H.json(H.job(status: .failed)), try H.json([ArtifactInfo]()), try H.json(entries)])
            .run(["logs", H.jobID.uuidString, "--raw"])
        #expect(raw.exitCode == 0)
        #expect(raw.out == lines.map { "08:00:00 [archive] \($0)\n" }.joined())
        #expect(await H(responses: []).run(["logs", H.jobID.uuidString, "--raw", "--follow"]).exitCode != 0)
    }

    @Test func statusExitCodeFollowsTheBuild() async throws {
        let cancelled = H.build(H.job(status: .cancelled))
        let result = await H(responses: [try H.json(cancelled), try H.json([H.app]), try H.json([Machine]())])
            .run(["status", H.buildID.uuidString])
        #expect(result.exitCode == 2)
    }

    @Test func invalidBuildIDIsAUsageError() async throws {
        let result = await H().run(["cancel", "not-a-uuid"])
        #expect(result.exitCode == 64)
    }

    @Test func undecodableResponseIsAnErrorLine() async throws {
        let result = await H(responses: [StubTransport.Response(body: "{\"nope\":1}")]).run(["apps", "list"])
        #expect(result.exitCode == 1)
        #expect(result.err.hasPrefix("error: the server at http://localhost:8787 sent a response the CLI cannot read: "))
        #expect(result.out.isEmpty)
    }
}
