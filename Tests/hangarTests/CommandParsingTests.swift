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
