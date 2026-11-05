import Foundation
import HangarAppStoreConnect
import HangarCore
import Logging
import Synchronization

/// The deploy check's warnings about the build itself, before it runs: what the repository's `ci_scripts` expect
/// that Hangar does not provide (`CIScriptsCheck`), and a missing Beta App Description when the workflow submits for
/// external beta review. Nothing here blocks a deploy, and a lookup that fails only means fewer warnings.
///
/// The Deploy sheet asks every 15 s, so the scripts are read once per commit (they never change) and App Store
/// Connect's answer is kept for five minutes per app.
final class DeployPreflight: Sendable {
    static let scriptsLifetime: TimeInterval = 600
    static let descriptionLifetime: TimeInterval = 300
    /// At most this many scripts are read, each at most this large.
    static let maxScripts = 20
    static let maxScriptBytes = 256 * 1024

    private let sourceHost: any SourceHost
    private let now: @Sendable () -> Date
    private let scripts = Mutex<[String: (scripts: [CIScript], expiresAt: Date)]>([:])
    private let descriptions = Mutex<[String: (present: Bool, expiresAt: Date)]>([:])
    private let logger = Logger(label: "app.hangar.server.preflight")

    init(sourceHost: any SourceHost, now: @escaping @Sendable () -> Date) {
        self.sourceHost = sourceHost
        self.now = now
    }

    func notices(
        app: App, workflow: Workflow, commit: String, token: String?, definedNames: Set<String>,
        appStoreConnect: () throws -> (any AppStoreConnectClient)?
    ) async -> [DeployCheckNotice] {
        var notices: [DeployCheckNotice] = []
        let directory = workflow.projectDirectory == "." ? "ci_scripts" : "\(workflow.projectDirectory)/ci_scripts"
        do {
            let found = try await ciScripts(app: app, commit: commit, directory: directory, token: token)
            let warnings = CIScriptsCheck.check(found, definedNames: definedNames)
            for script in warnings.undefined.keys.sorted() {
                let single = CIScriptsCheck.Warnings(undefined: [script: warnings.undefined[script] ?? []], notExecutable: [])
                notices += CIScriptsCheck.sentences(single, directory: directory)
                    .map { DeployCheckNotice(code: "undefined-variables", message: $0) }
            }
            notices += CIScriptsCheck.sentences(
                CIScriptsCheck.Warnings(undefined: [:], notExecutable: warnings.notExecutable), directory: directory)
                .map { DeployCheckNotice(code: "script-not-executable", message: $0) }
        } catch {
            logger.info("could not read \(directory) of \(app.slug) at \(commit): \(error)")
        }
        if Self.submitsForExternalReview(workflow), let present = await betaAppDescription(app: app, client: appStoreConnect),
            !present
        {
            notices.append(DeployCheckNotice(
                code: "beta-app-description-missing",
                message: "This workflow submits builds for external beta review, which needs a Beta App Description: add one in App Store Connect under TestFlight › Test Information. Without it the build still reaches internal testers."))
        }
        return notices
    }

    static func submitsForExternalReview(_ workflow: Workflow) -> Bool {
        workflow.postActions.contains { spec in
            guard spec.name == TestFlightSettings.actionName, let settings = try? TestFlightSettings(settings: spec.settings)
            else { return false }
            return settings.submitForExternalReview && settings.waitForProcessing
        }
    }

    /// `<directory>/*.sh` at `commit`, with whether each is executable.
    private func ciScripts(app: App, commit: String, directory: String, token: String?) async throws -> [CIScript] {
        let key = "\(app.id)|\(commit.lowercased())|\(directory)"
        let current = now()
        if let entry = scripts.withLock({ $0[key] }), entry.expiresAt > current { return entry.scripts }
        let tree = try await sourceHost.tree(repoURL: app.repoURL, commit: commit, token: token)
        let prefix = directory + "/"
        let paths = tree.paths
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".sh") && !$0.dropFirst(prefix.count).contains("/") }
            .sorted().prefix(Self.maxScripts)
        var found: [CIScript] = []
        for path in paths {
            guard let data = try await sourceHost.readData(
                repoURL: app.repoURL, commit: commit, path: path, token: token, maxBytes: Self.maxScriptBytes)
            else { continue }
            found.append(CIScript(
                name: String(path.dropFirst(prefix.count)), text: String(decoding: data, as: UTF8.self),
                executable: tree.executables.contains(path)))
        }
        scripts.withLock { entries in
            entries = entries.filter { $0.value.expiresAt > current }
            entries[key] = (found, current.addingTimeInterval(Self.scriptsLifetime))
        }
        return found
    }

    /// Whether the app has a Beta App Description in some locale; nil when App Store Connect cannot say.
    private func betaAppDescription(app: App, client: () throws -> (any AppStoreConnectClient)?) async -> Bool? {
        let current = now()
        if let entry = descriptions.withLock({ $0[app.appStoreConnectAppID] }), entry.expiresAt > current { return entry.present }
        do {
            guard let client = try client() else { return nil }
            let localizations = try await client.betaAppLocalizations(appID: app.appStoreConnectAppID)
            let present = localizations.contains { !($0.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            descriptions.withLock { entries in
                entries = entries.filter { $0.value.expiresAt > current }
                entries[app.appStoreConnectAppID] = (present, current.addingTimeInterval(Self.descriptionLifetime))
            }
            return present
        } catch {
            logger.info("could not read the Beta App Description of \(app.slug): \(error)")
            return nil
        }
    }
}
