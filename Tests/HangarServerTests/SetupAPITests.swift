import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing

@testable import HangarServer

/// An App Store Connect client whose `apps()` answers by the credentials it was built with: `refuse` decides
/// when App Store Connect says 401.
private struct GatedASC: AppStoreConnectClient {
    var credentials: ASCCredentials
    var refuse: @Sendable (ASCCredentials) -> Bool
    var apps: [ASCApp] = [
        ASCApp(id: "1", name: "Legilo", bundleID: "com.acme.legilo"),
        ASCApp(id: "2", name: "Atlas", bundleID: "com.acme.atlas"),
        ASCApp(id: "3", name: "Zeta", bundleID: "com.acme.zeta"),
    ]
    func builds(appID: String, version: String?) async throws -> [ASCBuild] { [] }
    func xcodeCloudRunNumbers(appID: String) async throws -> [Int] { [] }
    func apps() async throws -> [ASCApp] {
        if refuse(credentials) { throw ASCError.http(status: 401, body: "NOT_AUTHORIZED") }
        return apps
    }
    func appIconURL(appID: String) async throws -> String? { nil }
    func betaGroups(appID: String) async throws -> [ASCBetaGroup] { [] }
    func addBuild(_ buildID: String, toBetaGroup groupID: String) async throws {}
    func setWhatToTest(buildID: String, locale: String, text: String) async throws {}
    func submitForBetaReview(buildID: String) async throws {}
}

/// A worker installer that enrolls through the server the way the real script does, by redeeming the pairing
/// code from its environment; the handler is set once the server exists.
final class FakeInstaller: LocalWorkerInstaller {
    struct Run: Sendable {
        var script: String
        var environment: [String: String]
    }

    private let state = Mutex<(runs: [Run], handler: (@Sendable (Run) async throws -> Int32)?)>(([], nil))

    var runs: [Run] { state.withLock { $0.runs } }

    func handle(_ handler: @escaping @Sendable (Run) async throws -> Int32) {
        state.withLock { $0.handler = handler }
    }

    func run(script: String, environment: [String: String], onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let run = Run(script: script, environment: environment)
        let handler = state.withLock { state in
            state.runs.append(run)
            return state.handler
        }
        onLine("Installing the Hangar worker")
        return try await handler?(run) ?? 0
    }
}

private let pem = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg\n-----END PRIVATE KEY-----\n"
private let ghToken = "gho_supersecretclitoken"
private let pastedToken = "github_pat_supersecretpasted"

/// A temporary home directory with `AuthKey_*.p8` files in Apple's key folders.
private struct KeyHome {
    let home: URL
    let cwd: URL
    let custom: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-setup-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        cwd = root.appendingPathComponent("cwd")
        custom = root.appendingPathComponent("custom-keys")
        for directory in [home, cwd, custom] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    @discardableResult
    func write(_ relative: String, in base: URL? = nil, age: TimeInterval, contents: String = pem) throws -> String {
        let url = (base ?? home).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url.path
    }
}

private func setupEnvironment(
    _ keys: KeyHome, runner: RecordingProcessRunner = RecordingProcessRunner(), installer: FakeInstaller = FakeInstaller(),
    environment: [String: String] = [:]
) -> SetupEnvironment {
    SetupEnvironment(
        homeDirectory: keys.home.path, currentDirectory: keys.cwd.path,
        environment: ["PATH": "/usr/bin:/bin", "HOME": keys.home.path].merging(environment) { $1 },
        runner: runner, installer: installer)
}

private func isGh(_ arguments: [String]) -> @Sendable (ProcessCommand) -> Bool {
    { $0.executable.hasSuffix("env") && Array($0.arguments.drop { $0 != "gh" }.dropFirst()) == arguments }
}

private func scriptHostName(_ runner: RecordingProcessRunner, _ name: String = "studio") {
    runner.script({ $0.executable.hasSuffix("scutil") && $0.arguments == ["--get", "LocalHostName"] }, lines: [name])
}

@Suite(.timeLimit(.minutes(1))) struct SetupAPITests {
    // MARK: Status

    @Test func statusOfAFreshServer() async throws {
        let keys = try KeyHome()
        let runner = RecordingProcessRunner()
        scriptHostName(runner)
        let fixture = try APIFixture(setup: setupEnvironment(keys, runner: runner))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/setup", method: .get) { response throws in
                #expect(response.status == .ok)
                #expect(try decode(SetupStatus.self, response) == SetupStatus(
                    appStoreConnect: nil, github: nil, machines: 0, apps: 0, localWorker: false, localHostName: "studio"))
            }
        }
    }

    @Test func statusSeesTheLocalWorkerAppsAndGitHubLogin() async throws {
        let keys = try KeyHome()
        let runner = RecordingProcessRunner()
        scriptHostName(runner, "Studio")
        let github = StubTransport(responses: [.init(body: #"{"login":"rurza","id":1}"#)])
        let fixture = try APIFixture(githubTransport: github, setup: setupEnvironment(keys, runner: runner))
        _ = try fixture.server.machines.create(name: "studio", maxConcurrentJobs: 1)
        _ = try fixture.server.machines.create(name: "mini", maxConcurrentJobs: 1)
        try fixture.createApp()
        try fixture.server.variables.set(
            scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: pastedToken, isSecret: true))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/setup", method: .get) { response throws in
                let status = try decode(SetupStatus.self, response)
                #expect(status.machines == 2)
                #expect(status.apps == 1)
                #expect(status.localWorker)
                #expect(status.github == GitHubStatus(login: "rurza", source: .token))
                #expect(!String(buffer: response.body).contains(pastedToken))
            }
            // The login is cached: a second status asks GitHub no more.
            try await client.execute(uri: "/api/v1/settings", method: .get) { response throws in
                #expect(try decode(SettingsStatus.self, response).github == GitHubStatus(login: "rurza", source: .token))
            }
        }
        #expect(github.requests.count == 1)
    }

    // MARK: App Store Connect keys

    @Test func scanFindsAppleKeyFoldersNewestFirstAndIgnoresOtherNames() async throws {
        let keys = try KeyHome()
        let apple = try keys.write(".appstoreconnect/private_keys/AuthKey_F2MREDK7DC.p8", age: 3000)
        let downloads = try keys.write("Downloads/AuthKey_ZZ99YY88XX.p8", age: 10)
        let custom = try keys.write("AuthKey_CUSTOM1234.p8", in: keys.custom, age: 2000)
        let cwd = try keys.write("private_keys/AuthKey_CWD1234567.p8", in: keys.cwd, age: 1000)
        try keys.write("private_keys/AuthKey_HOME123456.p8", age: 500)
        try keys.write(".private_keys/AuthKey_DOT1234567.p8", age: 400)
        for ignored in [
            "Downloads/AuthKey_lower12345.p8", "Downloads/AuthKey_SHORT.p8", "Downloads/notes.p8",
            "Downloads/AuthKey_ABCDEFGHIJ.p8.txt", "Downloads/AuthKey_ABCDEFGHIJKLMN.p8", "Documents/AuthKey_ELSEWHERE1.p8",
        ] {
            try keys.write(ignored, age: 1)
        }
        let fixture = try APIFixture(
            setup: setupEnvironment(keys, environment: ["API_PRIVATE_KEYS_DIR": keys.custom.path]))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/setup/asc-keys", method: .get) { response throws in
                #expect(response.status == .ok)
                let found = try decode([FoundASCKey].self, response)
                #expect(found.map(\.keyID) == ["ZZ99YY88XX", "DOT1234567", "HOME123456", "CWD1234567", "CUSTOM1234", "F2MREDK7DC"])
                #expect(found.first?.path == downloads)
                #expect(found.first?.displayPath == "~/Downloads/AuthKey_ZZ99YY88XX.p8")
                #expect(found.contains { $0.path == apple && $0.displayPath == "~/.appstoreconnect/private_keys/AuthKey_F2MREDK7DC.p8" })
                #expect(found.contains { $0.path == custom })
                #expect(found.contains { $0.path == cwd })
                #expect(!String(buffer: response.body).contains("PRIVATE KEY"))
            }
        }
    }

    @Test func scanWithNoKeysIsEmpty() async throws {
        let fixture = try APIFixture(setup: setupEnvironment(try KeyHome()))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/setup/asc-keys", method: .get) { response throws in
                #expect(try decode([FoundASCKey].self, response) == [])
            }
        }
    }

    @Test func usingAKeyOnlyAcceptsScannedPaths() async throws {
        let keys = try KeyHome()
        try keys.write("Downloads/AuthKey_ZZ99YY88XX.p8", age: 10)
        let elsewhere = try keys.write("Documents/AuthKey_ELSEWHERE1.p8", age: 10)
        let built = Mutex(0)
        let fixture = try APIFixture(
            appStoreConnectFactory: { credentials in
                built.withLock { $0 += 1 }
                return GatedASC(credentials: credentials, refuse: { _ in false })
            }, setup: setupEnvironment(keys))
        try await fixture.test { client in
            for path in [elsewhere, "/etc/passwd", keys.home.path + "/Downloads/../Documents/AuthKey_ELSEWHERE1.p8"] {
                try await client.execute(
                    uri: "/api/v1/setup/asc-keys/use", method: .post, headers: jsonHeaders, body: try body(UseASCKeyRequest(path: path))
                ) { response throws in
                    #expect(response.status == .badRequest)
                    #expect(try decode(APIError.self, response).code == "asc_key_not_found")
                }
            }
        }
        #expect(built.withLock { $0 } == 0)
        #expect(try fixture.server.variables.value(global: "HANGAR_ASC_KEY_ID") == nil)
    }

    @Test func anIndividualKeyIsTestedThenSaved() async throws {
        let keys = try KeyHome()
        let path = try keys.write(".appstoreconnect/private_keys/AuthKey_F2MREDK7DC.p8", age: 10)
        let fixture = try APIFixture(
            appStoreConnectFactory: { GatedASC(credentials: $0, refuse: { _ in false }) }, setup: setupEnvironment(keys))
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/setup/asc-keys/use", method: .post, headers: jsonHeaders, body: try body(UseASCKeyRequest(path: path))
            ) { response throws in
                #expect(response.status == .ok)
                #expect(try decode(ASCKeyTestResult.self, response) == ASCKeyTestResult(kind: .individual, keyID: "F2MREDK7DC", appCount: 3))
                #expect(!String(buffer: response.body).contains("PRIVATE KEY"))
            }
            try await client.execute(uri: "/api/v1/setup", method: .get) { response throws in
                #expect(try decode(SetupStatus.self, response).appStoreConnect == ASCKeyStatus(keyID: "F2MREDK7DC", issuerID: nil))
            }
        }
        let summaries = try fixture.server.variables.summaries(scope: .global)
        #expect(try fixture.server.variables.value(global: "HANGAR_ASC_KEY_PATH") == pem)
        #expect(summaries.first { $0.name == "HANGAR_ASC_KEY_PATH" }?.isSecret == true)
        #expect(summaries.first { $0.name == "HANGAR_ASC_KEY_PATH" }?.asFile == true)
        #expect(try fixture.server.variables.value(global: "HANGAR_ASC_KEY_ID") == "F2MREDK7DC")
        #expect(try fixture.server.variables.value(global: "HANGAR_ASC_ISSUER_ID") == nil)
    }

    @Test func aTeamKeyAsksForItsIssuerID() async throws {
        let keys = try KeyHome()
        let path = try keys.write("Downloads/AuthKey_TEAM123456.p8", age: 10)
        let fixture = try APIFixture(
            appStoreConnectFactory: { GatedASC(credentials: $0, refuse: { $0.issuerID != "69a6de70-issuer" }) },
            setup: setupEnvironment(keys))
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/setup/asc-keys/use", method: .post, headers: jsonHeaders, body: try body(UseASCKeyRequest(path: path))
            ) { response throws in
                #expect(response.status == .conflict)
                let error = try decode(APIError.self, response)
                #expect(error.code == "issuer_required")
                #expect(error.message.contains("Issuer ID"))
            }
            #expect(try fixture.server.variables.value(global: "HANGAR_ASC_KEY_ID") == nil)
            // A wrong issuer is a rejected key, not another request for one.
            try await client.execute(
                uri: "/api/v1/setup/asc-keys/use", method: .post, headers: jsonHeaders,
                body: try body(UseASCKeyRequest(path: path, issuerID: "wrong"))
            ) { response throws in
                #expect(response.status == .badRequest)
                #expect(try decode(APIError.self, response).code == "asc_key_rejected")
            }
            try await client.execute(
                uri: "/api/v1/setup/asc-keys/use", method: .post, headers: jsonHeaders,
                body: try body(UseASCKeyRequest(path: path, issuerID: " 69a6de70-issuer "))
            ) { response throws in
                #expect(response.status == .ok)
                #expect(try decode(ASCKeyTestResult.self, response) == ASCKeyTestResult(kind: .team, keyID: "TEAM123456", appCount: 3))
            }
        }
        #expect(try fixture.server.variables.value(global: "HANGAR_ASC_ISSUER_ID") == "69a6de70-issuer")
        #expect(try fixture.server.variables.value(global: "HANGAR_ASC_KEY_ID") == "TEAM123456")
    }

    @Test func settingsSavesAnUploadedKeyOnlyAfterTestingIt() async throws {
        let fixture = try APIFixture(
            appStoreConnectFactory: { GatedASC(credentials: $0, refuse: { $0.issuerID != nil }) },
            setup: setupEnvironment(try KeyHome()))
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/settings/asc-key", method: .post, headers: jsonHeaders,
                body: try body(SaveASCKeyRequest(keyID: "ABC123DEFG", issuerID: "some-issuer", privateKey: pem))
            ) { response throws in
                #expect(response.status == .badRequest)
                #expect(try decode(APIError.self, response).code == "asc_key_rejected")
            }
            #expect(try fixture.server.variables.value(global: "HANGAR_ASC_KEY_PATH") == nil)
            try await client.execute(
                uri: "/api/v1/settings/asc-key", method: .post, headers: jsonHeaders,
                body: try body(SaveASCKeyRequest(keyID: "ABC123DEFG", privateKey: "not a key"))
            ) { response throws in
                #expect(response.status == .badRequest)
                #expect(try decode(APIError.self, response).code == "invalid_asc_key")
            }
            try await client.execute(
                uri: "/api/v1/settings/asc-key", method: .post, headers: jsonHeaders,
                body: try body(SaveASCKeyRequest(keyID: "ABC123DEFG", issuerID: "", privateKey: pem))
            ) { response throws in
                #expect(response.status == .ok)
                #expect(try decode(ASCKeyTestResult.self, response) == ASCKeyTestResult(kind: .individual, keyID: "ABC123DEFG", appCount: 3))
            }
        }
        #expect(try fixture.server.variables.value(global: "HANGAR_ASC_KEY_ID") == "ABC123DEFG")
    }

    // MARK: GitHub

    @Test func detectsTheGitHubCLILogin() async throws {
        let runner = RecordingProcessRunner()
        runner.script(isGh(["api", "user", "--jq", ".login"]), lines: ["rurza"])
        let fixture = try APIFixture(setup: setupEnvironment(try KeyHome(), runner: runner))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/setup/github", method: .get) { response throws in
                #expect(try decode(GitHubCLIStatus.self, response) == GitHubCLIStatus(ghLogin: "rurza"))
            }
        }
        let command = try #require(runner.commands.first { isGh(["api", "user", "--jq", ".login"])($0) })
        let path = command.environment["PATH"] ?? ""
        #expect(path.contains("/opt/homebrew/bin") && path.contains("/usr/bin"))
    }

    @Test func noGitHubCLILoginWhenGhFails() async throws {
        let runner = RecordingProcessRunner()
        runner.script(isGh(["api", "user", "--jq", ".login"]), lines: ["env: gh: No such file or directory"], exitCode: 127)
        let fixture = try APIFixture(setup: setupEnvironment(try KeyHome(), runner: runner))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/setup/github", method: .get) { response throws in
                #expect(try decode(GitHubCLIStatus.self, response) == GitHubCLIStatus(ghLogin: nil))
            }
        }
    }

    @Test func usingTheGitHubCLITokenStoresItWithoutShowingIt() async throws {
        let runner = RecordingProcessRunner()
        runner.script(isGh(["auth", "token", "--hostname", "github.com"]), lines: [ghToken])
        let github = StubTransport(responses: [.init(body: #"{"login":"rurza"}"#)])
        let fixture = try APIFixture(githubTransport: github, setup: setupEnvironment(try KeyHome(), runner: runner))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/setup/github/use-gh", method: .post) { response throws in
                #expect(response.status == .ok)
                #expect(try decode(GitHubLoginResponse.self, response) == GitHubLoginResponse(login: "rurza"))
                #expect(!String(buffer: response.body).contains(ghToken))
            }
            try await client.execute(uri: "/api/v1/setup", method: .get) { response throws in
                #expect(try decode(SetupStatus.self, response).github == GitHubStatus(login: "rurza", source: .gh))
                #expect(!String(buffer: response.body).contains(ghToken))
            }
        }
        #expect(try fixture.server.variables.value(global: "HANGAR_GITHUB_TOKEN") == ghToken)
        #expect(try fixture.server.variables.summaries(scope: .global).first { $0.name == "HANGAR_GITHUB_TOKEN" }?.isSecret == true)
        let request = try #require(github.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(ghToken)")
        // The token is read from gh's output, never passed to a command.
        #expect(!runner.commands.contains { $0.arguments.contains(ghToken) || $0.environment.values.contains(ghToken) })
    }

    @Test func useGhWithoutALoginExplainsHowToSignIn() async throws {
        let runner = RecordingProcessRunner()
        runner.script(isGh(["auth", "token", "--hostname", "github.com"]), lines: ["no oauth token found"], exitCode: 1)
        let fixture = try APIFixture(setup: setupEnvironment(try KeyHome(), runner: runner))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/setup/github/use-gh", method: .post) { response throws in
                #expect(response.status == .badRequest)
                let error = try decode(APIError.self, response)
                #expect(error.code == "gh_not_signed_in")
                #expect(error.message.contains("gh auth login"))
            }
        }
        #expect(try fixture.server.variables.value(global: "HANGAR_GITHUB_TOKEN") == nil)
    }

    @Test func aPastedTokenIsCheckedWithGitHubBeforeSaving() async throws {
        let github = StubTransport(responses: [
            .init(status: 401, body: #"{"message":"Bad credentials"}"#), .init(body: #"{"login":"rurza"}"#),
        ])
        let fixture = try APIFixture(githubTransport: github, setup: setupEnvironment(try KeyHome()))
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/settings/github-token", method: .post, headers: jsonHeaders,
                body: try body(SaveGitHubTokenRequest(token: "github_pat_wrong"))
            ) { response throws in
                #expect(response.status == .badRequest)
                #expect(try decode(APIError.self, response).code == "github_token_rejected")
                #expect(!String(buffer: response.body).contains("github_pat_wrong"))
            }
            #expect(try fixture.server.variables.value(global: "HANGAR_GITHUB_TOKEN") == nil)
            try await client.execute(
                uri: "/api/v1/settings/github-token", method: .post, headers: jsonHeaders,
                body: try body(SaveGitHubTokenRequest(token: " \(pastedToken) "))
            ) { response throws in
                #expect(response.status == .ok)
                #expect(try decode(GitHubLoginResponse.self, response) == GitHubLoginResponse(login: "rurza"))
            }
            try await client.execute(uri: "/api/v1/settings", method: .get) { response throws in
                #expect(try decode(SettingsStatus.self, response).github == GitHubStatus(login: "rurza", source: .token))
            }
        }
        #expect(try fixture.server.variables.value(global: "HANGAR_GITHUB_TOKEN") == pastedToken)
    }

    @Test func aTokenSetElsewhereAfterGhIsNoLongerReportedAsGh() async throws {
        let runner = RecordingProcessRunner()
        runner.script(isGh(["auth", "token", "--hostname", "github.com"]), lines: [ghToken])
        let github = StubTransport(responses: [.init(body: #"{"login":"rurza"}"#), .init(body: #"{"login":"other"}"#)])
        let fixture = try APIFixture(githubTransport: github, setup: setupEnvironment(try KeyHome(), runner: runner))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/setup/github/use-gh", method: .post) { #expect($0.status == .ok) }
            try fixture.server.variables.set(
                scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: pastedToken, isSecret: true))
            try await client.execute(uri: "/api/v1/setup", method: .get) { response throws in
                #expect(try decode(SetupStatus.self, response).github == GitHubStatus(login: "other", source: .token))
            }
        }
    }

    // MARK: This Mac

    private func localWorkerFixture(
        runner: RecordingProcessRunner = RecordingProcessRunner(), installer: FakeInstaller = FakeInstaller(),
        workerBinary: Bool = true, environment: [String: String] = [:]
    ) throws -> (APIFixture, KeyHome) {
        let keys = try KeyHome()
        scriptHostName(runner)
        var binary: String?
        if workerBinary { binary = try keys.write("bin/hangar-worker", in: keys.cwd, age: 0, contents: "#!/bin/sh\n") }
        let fixture = try APIFixture(
            workerBinaryPath: binary,
            setup: setupEnvironment(keys, runner: runner, installer: installer, environment: environment))
        return (fixture, keys)
    }

    private func waitForInstall(_ client: any TestClientProtocol) async throws -> LocalWorkerInstall {
        for _ in 0..<500 {
            let install = try await client.execute(uri: "/api/v1/setup/local-worker", method: .get) { response throws in
                try decode(LocalWorkerInstall.self, response)
            }
            if install.state != .running { return install }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the install did not finish")
        return LocalWorkerInstall(state: .running)
    }

    @Test func useThisMacRunsTheInstallScriptWithAFreshPairingCode() async throws {
        let installer = FakeInstaller()
        let (fixture, keys) = try localWorkerFixture(installer: installer, environment: ["HANGAR_WORKER_TOKEN": "leaked"])
        let server = fixture.server
        installer.handle { run in
            let code = try #require(run.environment["HANGAR_PAIRING_CODE"])
            let name = try #require(run.environment["HANGAR_MACHINE_NAME"])
            _ = try server.pairings.redeem(code, from: "127.0.0.1") { try server.createMachine(name: name, maxConcurrentJobs: 1) }
            return 0
        }
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/setup/local-worker", method: .get) { response throws in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/api/v1/setup/local-worker", method: .post) { response throws in
                #expect(response.status == .accepted)
                #expect(try decode(LocalWorkerInstall.self, response).state == .running)
            }
            let install = try await waitForInstall(client)
            #expect(install.state == .succeeded)
            #expect(install.machine?.name == "studio")
            #expect(install.lines.contains("Installing the Hangar worker"))
            try await client.execute(uri: "/api/v1/setup", method: .get) { response throws in
                #expect(try decode(SetupStatus.self, response).localWorker)
            }
        }
        let run = try #require(installer.runs.first)
        #expect(run.script.contains("HANGAR_SERVER='http://127.0.0.1:8787'"))
        #expect(run.environment["HANGAR_BIN_DIR"] == keys.home.path + "/.local/bin")
        #expect(run.environment["HANGAR_MACHINE_NAME"] == "studio")
        #expect(run.environment["HANGAR_WORKER_TOKEN"] == nil)
        #expect(run.environment["HOME"] == keys.home.path)
    }

    @Test func aFailedInstallReportsWhy() async throws {
        let installer = FakeInstaller()
        installer.handle { _ in 1 }
        let (fixture, _) = try localWorkerFixture(installer: installer)
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/setup/local-worker", method: .post) { #expect($0.status == .accepted) }
            let install = try await waitForInstall(client)
            #expect(install.state == .failed)
            #expect(install.message?.contains("exited with status 1") == true)
            #expect(install.machine == nil)
        }
    }

    @Test func useThisMacIsRefusedWhenItIsEnrolledOrThereIsNoWorker() async throws {
        let (enrolled, _) = try localWorkerFixture()
        _ = try enrolled.server.machines.create(name: "studio", maxConcurrentJobs: 1)
        try await enrolled.test { client in
            try await client.execute(uri: "/api/v1/setup/local-worker", method: .post) { response throws in
                #expect(response.status == .conflict)
                #expect(try decode(APIError.self, response).code == "machine_exists")
            }
        }
        let installer = FakeInstaller()
        let (noBinary, _) = try localWorkerFixture(installer: installer, workerBinary: false)
        try await noBinary.test { client in
            try await client.execute(uri: "/api/v1/setup/local-worker", method: .post) { response throws in
                #expect(response.status == .serviceUnavailable)
                #expect(try decode(APIError.self, response).code == "worker_binary_missing")
            }
        }
        #expect(installer.runs.isEmpty)
    }
}
