import Foundation
import HangarAppStoreConnect
import HangarCore
import Hummingbird

/// The first-run setup: what is configured, App Store Connect keys and the GitHub CLI login already on this Mac,
/// and installing the worker here. Key contents and tokens never leave the server; paths and key IDs do.
extension HangarServerApp {
    static let githubTokenSourceSetting = "github_token_source"

    func addSetupRoutes(to api: APIGroup) {
        api.get("setup") { _, context in
            let hostName = await localHostName.value(setup)
            let machines = try machines.all()
            let local = viewerIsLocal(context)
            return try Response.json(
                SetupStatus(
                    appStoreConnect: try Self.appStoreConnectCredentials(variables: variables).map {
                        ASCKeyStatus(keyID: $0.keyID, issuerID: $0.issuerID)
                    },
                    github: try await githubStatus(), machines: machines.count, apps: try apps.all().count,
                    localWorker: hostName.map { name in machines.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
                        ?? false,
                    localHostName: hostName,
                    workerInstallAvailable: InstallRoutes.workerBinary(at: configuration.workerBinaryPath) != nil,
                    viewerIsLocal: local, installedWorker: local ? await setup.installedWorker() : nil,
                    dedicatedUserRequired: setup.dedicatedUserRequired))
        }

        // MARK: App Store Connect

        api.get("setup/asc-keys") { _, context in
            try requireLocal(context)
            return try Response.json(await scanASCKeys())
        }
        api.post("setup/asc-keys/use") { request, context in
            try requireLocal(context)
            let input = try await request.decode(as: UseASCKeyRequest.self, context: context)
            // Only a file the scan finds right now: the request names a path, the server decides what it may read.
            guard let key = await scanASCKeys().first(where: { $0.path == input.path }) else {
                throw APIError(
                    code: "asc_key_not_found", message: "That key file is not one Hangar found on this Mac. Scan again or choose the file.")
            }
            guard let text = ASCKeyScanner.read(key.path) else {
                throw APIError(code: "asc_key_unreadable", message: "\(key.displayPath) cannot be read: check its permissions.")
            }
            let result = try await testAndSaveASCKey(keyID: key.keyID, issuerID: input.issuerID, privateKey: text)
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

        api.get("setup/github") { _, context in
            try requireLocal(context)
            return try Response.json(GitHubCLIStatus(ghLogin: await GitHubCLI(environment: setup).login()))
        }
        api.post("setup/github/use-gh") { _, context in
            try requireLocal(context)
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

        api.get("setup/local-worker") { _, context in
            try requireLocal(context)
            guard let install = localWorkerSetup.current else {
                throw APIError(code: "not_found", message: "No worker install has run since the server started.")
            }
            return try Response.json(install)
        }
        api.post("setup/local-worker") { _, context in
            try requireLocal(context)
            return try Response.json(try await startLocalWorkerInstall(), status: .accepted)
        }
    }

    // MARK: This Mac only

    /// The request's socket peer is this Mac. Never a header: only the channel's remote address counts.
    func viewerIsLocal(_ context: HangarRequestContext) -> Bool {
        guard !context.relayedByProxy else { return false }
        let peer = context.remoteAddress?.ipAddress
        if let check = setup.isLocalPeer { return check(peer) }
        return LocalPeer.isLocal(peer, boundHost: configuration.host, interfaces: LocalPeer.interfaceAddresses())
    }

    /// 403 `local_only` unless the request comes from this Mac: its keys, its gh login and installing a worker
    /// here are the owner's, not any tailnet peer's.
    func requireLocal(_ context: HangarRequestContext) throws {
        guard viewerIsLocal(context) else {
            throw APIError(code: "local_only", message: "Open Hangar on this Mac to use what's installed on it.")
        }
    }

    /// The key scan, off the cooperative pool: a first look at ~/Downloads may wait on a privacy prompt.
    func scanASCKeys() async -> [FoundASCKey] {
        let scanner = ASCKeyScanner(environment: setup)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: scanner.scan()) }
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
        return GitHubStatus(login: await githubAccounts.cachedLogin(token: token), source: source)
    }

    // MARK: This Mac

    /// `http://<bound host>:<port>`, or the loopback address when the server listens on every interface.
    var localOrigin: String? {
        let host = ["", "0.0.0.0", "::"].contains(configuration.host) ? "127.0.0.1" : configuration.host
        return InstallScript.origin(authority: host.contains(":") ? "[\(host)]:\(configuration.port)" : "\(host):\(configuration.port)")
    }

    /// Enrolls this Mac with a fresh pairing code by running the `/install` script here, for the server's user.
    /// Never touches a worker already set up on this Mac.
    func startLocalWorkerInstall() async throws -> LocalWorkerInstall {
        if let current = localWorkerSetup.current, current.state == .running { return current }
        if setup.dedicatedUserRequired {
            // The server must not sudo, and must not build as the user that holds master.key.
            let command = localOrigin.map { "curl -fsSL \($0)/install | sh" } ?? "the install command from Machines › Add Mac"
            throw APIError(
                code: "dedicated_user_required",
                message: "Builds run as a separate macOS user, not as \(setup.processUser), who runs Hangar's server. In Terminal on this Mac, as an administrator, run \(command): it creates the hangar user and sets up the worker there.")
        }
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
        guard configuration.port != 0, let origin = localOrigin else {
            throw APIError(
                code: "server_address_unusable",
                message: "The server listens on a port picked at start-up, which the worker cannot be given. Start it with --port.")
        }
        if let existing = await setup.installedWorker() {
            // The update command is only offered for the server the worker is set up for; with that unknown, any
            // command could point it at the wrong server.
            let message = if let serverURL = existing.serverURL {
                "A worker is already set up on this Mac (for \(serverURL)); to update it, run the install command again: curl -fsSL \(serverURL)/install | sh"
            } else {
                "A worker is already set up on this Mac (\(existing.agentLoaded ? "it is loaded in launchd" : "its configuration exists")), so Hangar leaves it alone. Check it with hangar-worker doctor on this Mac."
            }
            throw APIError(code: "worker_already_installed", message: message)
        }
        // The slot first, then the code: two clicks at once make one install and one code.
        guard let reserved = localWorkerSetup.reserve() else { return localWorkerSetup.current ?? LocalWorkerInstall(state: .running) }
        let code = pairings.create().code
        var environment = setup.scriptEnvironment
        environment["HANGAR_PAIRING_CODE"] = code
        environment["HANGAR_MACHINE_NAME"] = name
        if environment["HANGAR_BIN_DIR"] == nil {
            environment["HANGAR_BIN_DIR"] = URL(fileURLWithPath: setup.homeDirectory).appendingPathComponent(".local/bin").path
        }
        let script = InstallScript.render(
            origin: origin, workerSHA256: WorkerBinaryDigest.current(at: configuration.workerBinaryPath))
        let installer = setup.installer
        let machines = machines
        let childEnvironment = environment
        localWorkerSetup.run(
            secret: code,
            install: { onLine in try await installer.run(script: script, environment: childEnvironment, onLine: onLine) },
            finish: { try machines.all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame } })
        return reserved
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
