import CryptoKit
import Foundation
import GRDB
import HangarCore
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing

@testable import HangarServer

/// The App Store Connect key is a server setting (security review 2026-11-06, C1): migrated out of the variables,
/// refused as a variable name, and handed only to a worker that runs xcodebuild with it itself.
@Suite(.timeLimit(.minutes(1))) struct AppStoreConnectKeyTests {
    static let pem = "-----BEGIN PRIVATE KEY-----\nMIGT\n-----END PRIVATE KEY-----\n"

    @Test func migrationMovesTheGlobalsIntoTheSettingAndDropsEveryASCVariable() throws {
        let database = try Database(path: ":memory:")
        try Migrations.migrator.migrate(database.pool, upTo: "v10")
        let box = SecretBox(key: SymmetricKey(size: .bits256))
        let appID = UUID()
        try database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO apps (id, slug, name, repo_url, app_store_connect_app_id, created_at) VALUES (?, 'legilo', 'Legilo', 'r', '1', 0)",
                arguments: [appID.uuidString])
            for (scope, owner, name, value) in [
                ("global", "", "HANGAR_ASC_KEY_ID", "KEY123"), ("global", "", "HANGAR_ASC_ISSUER_ID", "issuer-uuid"),
                ("global", "", "HANGAR_ASC_KEY_PATH", Self.pem), ("global", "", "SENTRY_ORG", "acme"),
                ("app", appID.uuidString, "HANGAR_ASC_KEY_PATH", "an app's own copy"),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO variables (id, scope, owner_id, name, workflows, ciphertext, is_secret, as_file, updated_at)
                        VALUES (?, ?, ?, ?, '', ?, 1, 0, 1)
                        """,
                    arguments: [UUID().uuidString, scope, owner, name, try box.seal(value)])
            }
        }
        try database.migrate()

        let keys = AppStoreConnectKeyRepository(database: database, box: box)
        #expect(try keys.key(.main) == AppStoreConnectKey(keyID: "KEY123", issuerID: "issuer-uuid", privateKey: Self.pem))
        #expect(try keys.key(.development) == nil)
        let names = try database.pool.read { db in try String.fetchAll(db, sql: "SELECT name FROM variables ORDER BY name") }
        #expect(names == ["SENTRY_ORG"])
    }

    @Test func migrationWithoutAKeyStoresNone() throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let keys = AppStoreConnectKeyRepository(database: database, box: SecretBox(key: SymmetricKey(size: .bits256)))
        #expect(try keys.key(.main) == nil)
    }

    @Test func anEmptyIssuerIsAnIndividualKey() throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let keys = AppStoreConnectKeyRepository(database: database, box: SecretBox(key: SymmetricKey(size: .bits256)))
        try keys.set(.main, AppStoreConnectKey(keyID: "IND1", issuerID: "", privateKey: Self.pem))
        #expect(try keys.key(.main)?.issuerID == nil)
        #expect(try keys.status(.main) == ASCKeyStatus(keyID: "IND1", issuerID: nil))
        #expect(try keys.remove(.main))
        #expect(try keys.key(.main) == nil)
    }

    @Test func theOldNamesAreRefusedAsVariablesAtEveryScope() async throws {
        let fixture = try APIFixture()
        let app = try fixture.createApp()
        for scope in [VariableScope.global, .app(app.id)] {
            #expect {
                try fixture.server.variables.set(scope: scope, name: "HANGAR_ASC_KEY_PATH", input: VariableInput(value: "x", isSecret: true))
            } throws: { ($0 as? APIError)?.code == "reserved_variable" }
        }
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/variables/HANGAR_ASC_KEY_ID", method: .put, headers: jsonHeaders,
                body: try body(VariableInput(value: "KEY"))
            ) { response throws in
                #expect(response.status == .badRequest)
                #expect(try decode(APIError.self, response).message.contains("Settings › App Store Connect"))
            }
        }
    }
}

/// Which assignments carry the key: never in `environment`; a host Mac's archive and test; a VM Mac's archive only
/// (its host exports and uploads), never a VM Mac's test.
@Suite(.timeLimit(.minutes(1))) struct AppStoreConnectKeyAssignmentTests {
    static let key = AppStoreConnectKey(keyID: "TEAM1", issuerID: "issuer", privateKey: AppStoreConnectKeyTests.pem)

    private func vmReport() -> MachineReport {
        var report = WorkerAPITests.report()
        report.vm = VMReport(slots: 1, configuredSlots: 1, freeSlots: 1, storageFreeGB: 200, networkFilter: true)
        return report
    }

    private func assignments(_ setup: WorkerAPITests.Setup) async throws -> [ActionKind: JobAssignment] {
        let seen = Mutex<[ActionKind: JobAssignment]>([:])
        let server = setup.fixture.server
        try await setup.fixture.test { client throws in
            for _ in 0..<2 {
                let assignment = try await client.execute(uri: "/api/v1/worker/jobs/next?wait=0", method: .get, headers: setup.auth) {
                    try decode(JobAssignment.self, $0)
                }
                seen.withLock { $0[assignment.job.action.kind] = assignment }
                try server.builds.setJobStatus(id: assignment.job.id, status: .cancelled, at: WorkerAPITests.t0)
            }
        }
        return seen.withLock { $0 }
    }

    @Test func aHostMacGetsItForArchivesAndTestsButNeverAsAVariable() async throws {
        let setup = try await WorkerAPITests.Setup(workflow: "ci")
        try setup.fixture.server.ascKeys.set(.main, Self.key)
        try setup.fixture.server.machines.updateReport(
            id: setup.machine.id, report: WorkerAPITests.report(), seenAt: WorkerAPITests.t0)
        let seen = try await assignments(setup)
        #expect(seen[.archive]?.appStoreConnectKey == Self.key)
        #expect(seen[.test]?.appStoreConnectKey == Self.key)
        for assignment in seen.values {
            #expect(!assignment.environment.contains { $0.name.hasPrefix("HANGAR_ASC_") || $0.value.contains("PRIVATE KEY") })
        }
    }

    @Test func aVMMacGetsItOnlyForAnArchive() async throws {
        let setup = try await WorkerAPITests.Setup(workflow: "ci")
        try setup.fixture.server.ascKeys.set(.main, Self.key)
        try setup.fixture.server.machines.updateReport(id: setup.machine.id, report: vmReport(), seenAt: WorkerAPITests.t0)
        let seen = try await assignments(setup)
        #expect(seen[.archive]?.appStoreConnectKey == Self.key)
        #expect(seen[.test]?.appStoreConnectKey == nil)
    }

    @Test func noStoredKeyMeansNone() async throws {
        let setup = try await WorkerAPITests.Setup(workflow: "ci")
        let seen = try await assignments(setup)
        #expect(seen.values.allSatisfy { $0.appStoreConnectKey == nil })
    }

    @Test func itsDescriptionNeverShowsTheKey() {
        #expect(!"\(Self.key)".contains("PRIVATE"))
        #expect(!String(reflecting: Self.key).contains("PRIVATE"))
    }
}
