import CryptoKit
import Foundation
import GRDB
import HangarCore
import Hummingbird
import HummingbirdTesting
import Testing

@testable import HangarServer

/// Global secrets are opt-in per app (security review 2026-11-06, C1); plain globals stay inherited, and the
/// precedence is otherwise unchanged.
@Suite(.timeLimit(.minutes(1))) struct GlobalSecretsTests {
    func make() throws -> (HangarServer.Database, VariableRepository, AppRepository) {
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        return (database, VariableRepository(database: database, box: SecretBox(key: SymmetricKey(size: .bits256))), AppRepository(database: database))
    }

    func app(_ apps: AppRepository, _ name: String) throws -> App {
        try apps.create(CreateAppRequest(name: name, repoURL: "https://example.com/\(name).git", appStoreConnectAppID: name))
    }

    func names(_ variables: VariableRepository, _ app: App) throws -> [String] {
        try variables.resolvedEntries(appID: app.id, workflow: nil).map(\.name)
    }

    @Test func migrationGrantsEveryExistingAppTheSecretsItGotBefore() throws {
        let database = try HangarServer.Database(path: ":memory:")
        try Migrations.migrator.migrate(database.pool, upTo: "v12")
        let box = SecretBox(key: SymmetricKey(size: .bits256))
        let ids = [UUID(), UUID()]
        try database.pool.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: "INSERT INTO apps (id, slug, name, repo_url, app_store_connect_app_id, created_at) VALUES (?, ?, ?, 'r', '1', 0)",
                    arguments: [id.uuidString, "app\(index)", "App \(index)"])
            }
            for (name, secret) in [("SENTRY_AUTH_TOKEN", true), ("SENTRY_ORG", false), ("HANGAR_GITHUB_TOKEN", true)] {
                try db.execute(
                    sql: """
                        INSERT INTO variables (id, scope, owner_id, name, workflows, ciphertext, is_secret, as_file, updated_at)
                        VALUES (?, 'global', '', ?, '', ?, ?, 0, 1)
                        """,
                    arguments: [UUID().uuidString, name, try box.seal("v"), secret])
            }
        }
        try database.migrate()
        let grants = try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT app_id, name FROM app_global_secrets ORDER BY app_id, name").map { "\($0["name"] as String)" }
        }
        #expect(grants == ["SENTRY_AUTH_TOKEN", "SENTRY_AUTH_TOKEN"])
        let variables = VariableRepository(database: database, box: box)
        for id in ids {
            #expect(try variables.resolvedEntries(appID: id, workflow: nil).map(\.name) == [
                "HANGAR_GITHUB_TOKEN", "SENTRY_AUTH_TOKEN", "SENTRY_ORG",
            ])
        }
    }

    @Test func aNewGlobalSecretReachesOnlyTheAppsThatChooseIt() throws {
        let (_, variables, apps) = try make()
        let legilo = try app(apps, "legilo")
        let batfi = try app(apps, "batfi")
        try variables.set(scope: .global, name: "SENTRY_AUTH_TOKEN", input: VariableInput(value: "t", isSecret: true))
        try variables.set(scope: .global, name: "SENTRY_ORG", input: VariableInput(value: "acme"))
        try variables.set(scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "ghp", isSecret: true))
        #expect(try names(variables, legilo) == ["HANGAR_GITHUB_TOKEN", "SENTRY_ORG"])

        try variables.grantGlobalSecret(appID: legilo.id, name: "SENTRY_AUTH_TOKEN")
        #expect(try names(variables, legilo) == ["HANGAR_GITHUB_TOKEN", "SENTRY_AUTH_TOKEN", "SENTRY_ORG"])
        #expect(try names(variables, batfi) == ["HANGAR_GITHUB_TOKEN", "SENTRY_ORG"])
        #expect(try variables.globalSecrets(appID: legilo.id) == [GlobalSecretGrant(name: "SENTRY_AUTH_TOKEN", asFile: false, granted: true)])
        #expect(try variables.globalSecrets(appID: batfi.id) == [GlobalSecretGrant(name: "SENTRY_AUTH_TOKEN", asFile: false, granted: false)])
        #expect(try variables.effective(appID: batfi.id, workflow: nil).map(\.name) == ["HANGAR_GITHUB_TOKEN", "SENTRY_ORG"])

        try variables.revokeGlobalSecret(appID: legilo.id, name: "SENTRY_AUTH_TOKEN")
        #expect(try names(variables, legilo) == ["HANGAR_GITHUB_TOKEN", "SENTRY_ORG"])
    }

    @Test func precedenceIsUnchangedForWhatAnAppGets() throws {
        let (_, variables, apps) = try make()
        let legilo = try app(apps, "legilo")
        try variables.set(scope: .global, name: "TOKEN", input: VariableInput(value: "global", isSecret: true))
        // The app's own value needs no grant and wins either way.
        try variables.set(scope: .app(legilo.id), name: "TOKEN", input: VariableInput(value: "own", isSecret: true))
        #expect(try variables.resolvedEntries(appID: legilo.id, workflow: nil).first?.value == "own")
        try variables.grantGlobalSecret(appID: legilo.id, name: "TOKEN")
        let effective = try variables.effective(appID: legilo.id, workflow: nil)
        #expect(effective.first?.source.kind == .app)
        #expect(effective.first?.replaces.map(\.kind) == [.global])
    }

    @Test func aPlainGlobalThatBecomesSecretKeepsReachingEveryApp() throws {
        let (_, variables, apps) = try make()
        let legilo = try app(apps, "legilo")
        try variables.set(scope: .global, name: "SENTRY_DSN", input: VariableInput(value: "dsn"))
        try variables.set(scope: .global, name: "SENTRY_DSN", input: VariableInput(value: "dsn", isSecret: true))
        #expect(try names(variables, legilo) == ["SENTRY_DSN"])
        // A later app does not get it.
        let later = try app(apps, "later")
        #expect(try names(variables, later) == [])
    }

    @Test func deletingTheGlobalForgetsWhoHadIt() throws {
        let (_, variables, apps) = try make()
        let legilo = try app(apps, "legilo")
        try variables.set(scope: .global, name: "KEY", input: VariableInput(value: "1", isSecret: true))
        try variables.grantGlobalSecret(appID: legilo.id, name: "KEY")
        try variables.delete(scope: .global, name: "KEY")
        try variables.set(scope: .global, name: "KEY", input: VariableInput(value: "2", isSecret: true))
        #expect(try names(variables, legilo) == [])
    }

    @Test func onlyAnExistingGlobalSecretCanBeGranted() throws {
        let (_, variables, apps) = try make()
        let legilo = try app(apps, "legilo")
        try variables.set(scope: .global, name: "PLAIN", input: VariableInput(value: "1"))
        try variables.set(scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "ghp", isSecret: true))
        for name in ["MISSING", "PLAIN", "HANGAR_GITHUB_TOKEN"] {
            #expect { try variables.grantGlobalSecret(appID: legilo.id, name: name) } throws: {
                ($0 as? APIError)?.code == "variable_not_found"
            }
        }
    }

    @Test func theAppRoutesListGrantAndRevoke() async throws {
        let fixture = try APIFixture()
        let app = try fixture.createApp()
        try fixture.server.variables.set(scope: .global, name: "SENTRY_AUTH_TOKEN", input: VariableInput(value: "t", isSecret: true))
        try fixture.server.variables.set(scope: .global, name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "ghp", isSecret: true))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/global-secrets", method: .get) { response throws in
                #expect(try decode(AppGlobalSecrets.self, response) == AppGlobalSecrets(
                    secrets: [GlobalSecretGrant(name: "SENTRY_AUTH_TOKEN", asFile: false, granted: false)], gitHubToken: .global))
                #expect(!String(buffer: response.body).contains("\"t\""))
            }
            try await client.execute(uri: "/api/v1/apps/legilo/global-secrets/SENTRY_AUTH_TOKEN", method: .put) { response throws in
                #expect(response.status == .noContent)
            }
            try await client.execute(uri: "/api/v1/apps/legilo/global-secrets/NOPE", method: .put) { response throws in
                #expect(response.status == .notFound)
            }
        }
        #expect(try fixture.server.variables.globalSecrets(appID: app.id).first?.granted == true)
        try fixture.server.variables.set(scope: .app(app.id), name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "github_pat_x", isSecret: true))
        try await fixture.test { client in
            try await client.execute(uri: "/api/v1/apps/legilo/global-secrets", method: .get) { response throws in
                #expect(try decode(AppGlobalSecrets.self, response).gitHubToken == .app)
            }
            try await client.execute(uri: "/api/v1/apps/legilo/global-secrets/SENTRY_AUTH_TOKEN", method: .delete) { response throws in
                #expect(response.status == .noContent)
            }
        }
        #expect(try fixture.server.variables.globalSecrets(appID: app.id).first?.granted == false)
        // Reading is scope read; no API token may change who gets a secret.
        #expect(APITokenPolicy.required(method: .get, path: "apps/legilo/global-secrets") == .read)
        #expect(APITokenPolicy.required(method: .put, path: "apps/legilo/global-secrets/X") == nil)
        #expect(APITokenPolicy.required(method: .delete, path: "apps/legilo/global-secrets/X") == nil)
    }
}
