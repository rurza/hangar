import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird

/// The first-run setup: what is configured, App Store Connect keys and the GitHub CLI login already on this Mac,
/// and installing the worker here. Key contents and tokens never leave the server; paths and key IDs do.
extension HangarServerApp {
    static let githubTokenSourceSetting = "github_token_source"

    func addSetupRoutes(to api: APIGroup) {
        api.get("setup") { _, _ in
            let hostName = await localHostName.value(setup)
            let machines = try machines.all()
            return try Response.json(
                SetupStatus(
                    appStoreConnect: try Self.appStoreConnectCredentials(variables: variables).map {
                        ASCKeyStatus(keyID: $0.keyID, issuerID: $0.issuerID)
                    },
                    github: try await githubStatus(), machines: machines.count, apps: try apps.all().count,
                    localWorker: hostName.map { name in machines.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
                        ?? false,
                    localHostName: hostName,
                    workerInstallAvailable: InstallRoutes.workerBinary(at: configuration.workerBinaryPath) != nil))
        }

        // MARK: App Store Connect

        api.get("setup/asc-keys") { _, _ in try Response.json(ASCKeyScanner(environment: setup).scan()) }
        api.post("setup/asc-keys/use") { request, context in
            let input = try await request.decode(as: UseASCKeyRequest.self, context: context)
            // Only a file the scan finds right now: the request names a path, the server decides what it may read.
            guard let key = ASCKeyScanner(environment: setup).scan().first(where: { $0.path == input.path }) else {
                throw APIError(
                    code: "asc_key_not_found", message: "That key file is not one Hangar found on this Mac. Scan again or choose the file.")
            }
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: key.path))
            } catch {
                throw APIError(code: "asc_key_unreadable", message: "\(key.displayPath) cannot be read: check its permissions.")
            }
            let result = try await testAndSaveASCKey(
                keyID: key.keyID, issuerID: input.issuerID, privateKey: String(decoding: data, as: UTF8.self))
            return try Response.json(result)
        }
        api.post("settings/asc-key") { request, context in
            let input = try await request.decode(as: SaveASCKeyRequest.self, context: context)
            let keyID = input.keyID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard keyID.wholeMatch(of: /[A-Za-z0-9]{1,32}/) != nil else {
                throw APIError(code: "invalid_key_id", message: "Enter the key ID: the letters and digits after AuthKey_ in the file name.")
            }
            return try Response.json(
                try await testAndSaveASCKey(keyID: keyID, issuerID: input.issuerID, privateKey: input.privateKey))
        }

        // MARK: GitHub

        api.get("setup/github") { _, _ in try Response.json(GitHubCLIStatus(ghLogin: await GitHubCLI(environment: setup).login())) }
        api.post("setup/github/use-gh") { _, _ in
            let token = try await GitHubCLI(environment: setup).token()
            return try Response.json(GitHubLoginResponse(login: try await saveGitHubToken(token, source: .gh)))
        }
        api.post("settings/github-token") { request, context in
            let token = try await request.decode(as: SaveGitHubTokenRequest.self, context: context).token
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, !token.contains(where: \.isWhitespace) else {
                throw APIError(code: "invalid_token", message: "Paste the whole token: one word, no spaces.")
            }
            return try Response.json(GitHubLoginResponse(login: try await saveGitHubToken(token, source: .token)))
        }

        // MARK: This Mac

        api.get("setup/local-worker") { _, _ in
            guard let install = localWorkerSetup.current else {
                throw APIError(code: "not_found", message: "No worker install has run since the server started.")
            }
            return try Response.json(install)
        }
        api.post("setup/local-worker") { _, _ in
            try Response.json(try await startLocalWorkerInstall(), status: .accepted)
        }
    }

    // MARK: App Store Connect

    /// Asks App Store Connect for the key's apps; only a key it accepts is stored, in the three `HANGAR_ASC_*`
    /// globals the Settings page uses. A 401 without an issuer ID means a team key: 409 `issuer_required`.
    func testAndSaveASCKey(keyID: String, issuerID: String?, privateKey: String) async throws -> ASCKeyTestResult {
        let issuerID = issuerID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard privateKey.contains("PRIVATE KEY") else { throw Self.invalidASCKey }
        let credentials = ASCCredentials(keyID: keyID, issuerID: issuerID, privateKeyPEM: privateKey)
        let apps: [ASCApp]
        do {
            apps = try await appStoreConnectFactory(credentials).apps()
        } catch ASCError.invalidPrivateKey {
            throw Self.invalidASCKey
        } catch ASCError.http(let status, _) where status == 401 {
            if issuerID == nil {
                throw APIError(
                    code: "issuer_required",
                    message: "This key needs its Issuer ID (App Store Connect › Users and Access › Integrations).")
            }
            throw APIError(
                code: "asc_key_rejected",
                message: "App Store Connect did not accept key \(keyID) with this Issuer ID. Check the Issuer ID, or that the key was not revoked.")
        } catch ASCError.http(let status, _) where status == 403 {
            throw APIError(
                code: "asc_key_forbidden",
                message: "App Store Connect accepted key \(keyID) but it cannot list apps. Give it the App Manager role (or Admin).")
        } catch let error as ASCError {
            throw APIError(code: "asc_unavailable", message: "App Store Connect could not be asked: \(Self.appStoreConnectReason(error)).")
        }
        // The key ID goes last: the key counts as configured once the ID and the key are both set.
        try variables.set(scope: .global, name: "HANGAR_ASC_KEY_PATH", input: VariableInput(value: privateKey, isSecret: true, asFile: true))
        if let issuerID {
            try variables.set(scope: .global, name: "HANGAR_ASC_ISSUER_ID", input: VariableInput(value: issuerID))
        } else {
            try variables.delete(scope: .global, name: "HANGAR_ASC_ISSUER_ID")
        }
        try variables.set(scope: .global, name: "HANGAR_ASC_KEY_ID", input: VariableInput(value: keyID))
        return ASCKeyTestResult(kind: issuerID == nil ? .individual : .team, keyID: keyID, appCount: apps.count)
    }

    static let invalidASCKey = APIError(
        code: "invalid_asc_key", message: "That is not an App Store Connect API key (.p8). Download the key again and choose that file.")

    // MARK: GitHub

    /// Checks `token` with GitHub, then stores it as the global `HANGAR_GITHUB_TOKEN` and remembers its source.
    func saveGitHubToken(_ token: String, source: GitHubStatus.Source) async throws -> String {
        let login = try await githubAccounts.login(token: token)
        try variables.set(scope: .global, name: BuildService.tokenVariable, input: VariableInput(value: token, isSecret: true))
        try serverSettings.set(Self.githubTokenSourceSetting, source == .gh ? "gh:\(GitHubAccounts.hexHash(token))" : nil)
        return login
    }

    /// The global token's account and source; nil without a token. The login is nil when GitHub cannot be asked.
    /// The token counts as gh's only while it is the very token copied from gh.
    func githubStatus() async throws -> GitHubStatus? {
        guard let token = try globalGitHubToken() else { return nil }
        let marker = try serverSettings.value(Self.githubTokenSourceSetting)
        let source: GitHubStatus.Source = marker == "gh:\(GitHubAccounts.hexHash(token))" ? .gh : .token
        return GitHubStatus(login: try? await githubAccounts.login(token: token), source: source)
    }

    // MARK: This Mac

    /// `http://<bound host>:<port>`, or the loopback address when the server listens on every interface.
    var localOrigin: String? {
        let host = ["", "0.0.0.0", "::"].contains(configuration.host) ? "127.0.0.1" : configuration.host
        return InstallScript.origin(authority: host.contains(":") ? "[\(host)]:\(configuration.port)" : "\(host):\(configuration.port)")
    }

    /// Enrolls this Mac with a fresh pairing code by running the `/install` script here, for the server's user.
    func startLocalWorkerInstall() async throws -> LocalWorkerInstall {
        if let current = localWorkerSetup.current, current.state == .running { return current }
        guard let name = await localHostName.value(setup) else {
            throw APIError(code: "host_name_unknown", message: "Hangar cannot read this Mac's name (scutil --get LocalHostName).")
        }
        if try machines.all().contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw APIError(code: "machine_exists", message: "\(name) is already one of Hangar's machines.")
        }
        guard InstallRoutes.workerBinary(at: configuration.workerBinaryPath) != nil else {
            throw APIError(
                code: "worker_binary_missing",
                message: "This server has no hangar-worker to install. Reinstall the server with the latest scripts/server/install-server.sh.")
        }
        guard let origin = localOrigin else {
            throw APIError(code: "invalid_request", message: "The server's address cannot be used to install the worker.")
        }
        let code = pairings.create().code
        var environment = setup.childEnvironment
        environment["HANGAR_WORKER_TOKEN"] = nil
        environment["HANGAR_PAIRING_CODE"] = code
        environment["HANGAR_MACHINE_NAME"] = name
        if environment["HANGAR_BIN_DIR"]?.isEmpty ?? true {
            environment["HANGAR_BIN_DIR"] = URL(fileURLWithPath: setup.homeDirectory).appendingPathComponent(".local/bin").path
        }
        let script = InstallScript.render(origin: origin)
        let installer = setup.installer
        let machines = machines
        let childEnvironment = environment
        return localWorkerSetup.start(
            secret: code,
            install: { onLine in try await installer.run(script: script, environment: childEnvironment, onLine: onLine) },
            finish: { try machines.all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame } })
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
