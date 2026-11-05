import CryptoKit
import Foundation
import GRDB
import HangarCore
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing

@testable import HangarServer

/// Variable groups and per-workflow app variables (variable scopes design): the migration, the precedence rules and
/// the conflicts the repository refuses.
@Suite struct VariableScopesTests {
    func make() throws -> (HangarServer.Database, VariableRepository, App) {
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        let variables = VariableRepository(database: database, box: SecretBox(key: SymmetricKey(size: .bits256)))
        let app = try AppRepository(database: database).create(
            CreateAppRequest(name: "Legilo", repoURL: "https://example.com/r.git", appStoreConnectAppID: "1"))
        return (database, variables, app)
    }

    func values(_ variables: VariableRepository, _ app: App, _ workflow: String?) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try variables.resolvedEntries(appID: app.id, workflow: workflow).map { ($0.name, $0.value) })
    }

    @Test func migrationKeepsExistingVariablesForAllWorkflows() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v8")
        let box = SecretBox(key: SymmetricKey(size: .bits256))
        let appID = UUID()
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO apps (id, slug, name, repo_url, app_store_connect_app_id, created_at) VALUES (?, 'legilo', 'Legilo', 'r', '1', 0)",
                arguments: [appID.uuidString])
            for (scope, owner, name, value, secret) in [
                ("global", "", "SENTRY_ORG", "acme", false), ("global", "", "SENTRY_DSN", "global-dsn", false),
                ("app", appID.uuidString, "SENTRY_DSN", "app-dsn", false), ("app", appID.uuidString, "SENTRY_AUTH_TOKEN", "t", true),
            ] {
                try db.execute(
                    sql: "INSERT INTO variables (scope, app_id, name, ciphertext, is_secret, as_file, updated_at) VALUES (?, ?, ?, ?, ?, 0, 1)",
                    arguments: [scope, owner, name, try box.seal(value), secret])
            }
        }
        try Migrations.migrator.migrate(queue)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, scope, owner_id, name, workflows FROM variables ORDER BY scope, name")
        }
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { ($0["workflows"] as String) == "" && UUID(uuidString: $0["id"]) != nil })
        #expect(Set(rows.map { $0["owner_id"] as String }) == ["", appID.uuidString])

        let summaries = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT name FROM variables WHERE scope = 'app' AND owner_id = ? ORDER BY name", arguments: [appID.uuidString])
                .map { $0["name"] as String }
        }
        #expect(summaries == ["SENTRY_AUTH_TOKEN", "SENTRY_DSN"])
        let unique = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_list(variables)").map { $0["name"] as String }
        }
        #expect(unique.contains("variables_owner"))
    }

    @Test func migratedDataResolvesAsBefore() throws {
        // The repository over a database migrated from v8 data.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("hangar.sqlite").path
        let box = SecretBox(key: SymmetricKey(size: .bits256))
        let appID = UUID()
        do {
            let pool = try DatabasePool(path: path)
            try Migrations.migrator.migrate(pool, upTo: "v8")
            try pool.write { db in
                try db.execute(
                    sql: "INSERT INTO apps (id, slug, name, repo_url, app_store_connect_app_id, created_at) VALUES (?, 'legilo', 'Legilo', 'r', '1', 0)",
                    arguments: [appID.uuidString])
                try db.execute(
                    sql: "INSERT INTO variables (scope, app_id, name, ciphertext, is_secret, as_file, updated_at) VALUES ('global', '', 'A', ?, 0, 0, 1), ('app', ?, 'A', ?, 1, 1, 1)",
                    arguments: [try box.seal("global"), appID.uuidString, try box.seal("app")])
            }
        }
        let database = try HangarServer.Database(path: path)
        try database.migrate()
        let variables = VariableRepository(database: database, box: box)
        for workflow in [nil, "beta", "release"] as [String?] {
            #expect(try variables.resolvedEntries(appID: appID, workflow: workflow)
                == [EnvEntry(name: "A", value: "app", isSecret: true, asFile: true)])
        }
        #expect(try variables.summaries(scope: .app(appID)).map(\.workflows) == [[]])
    }

    @Test func precedenceFromMostSpecificToGlobal() throws {
        let (_, variables, app) = try make()
        try variables.set(scope: .global, name: "N", input: VariableInput(value: "global"))
        let shared = try variables.createGroup(name: "Shared")
        let beta = try variables.createGroup(name: "Beta only")
        try variables.set(scope: .group(shared.id), name: "N", input: VariableInput(value: "group-all"))
        try variables.set(scope: .group(beta.id), name: "N", input: VariableInput(value: "group-beta"))
        try variables.link(appID: app.id, group: "Shared", workflows: [])
        try variables.link(appID: app.id, group: "beta ONLY", workflows: ["Beta"])  // names match in any case

        #expect(try values(variables, app, "Release")["N"] == "group-all")
        #expect(try values(variables, app, "Beta")["N"] == "group-beta")  // a group limited to W beats one for all
        #expect(try values(variables, app, nil)["N"] == "group-all")

        try variables.set(scope: .app(app.id), name: "N", input: VariableInput(value: "app-all"))
        #expect(try values(variables, app, "Beta")["N"] == "app-all")
        try variables.set(scope: .app(app.id), name: "N", input: VariableInput(value: "app-beta", workflows: ["Beta"]))
        #expect(try values(variables, app, "Beta")["N"] == "app-beta")
        #expect(try values(variables, app, "Release")["N"] == "app-all")
        #expect(try values(variables, app, nil)["N"] == "app-all")

        let effective = try variables.effective(appID: app.id, workflow: "Beta")
        #expect(effective.map(\.name) == ["N"])
        #expect(effective[0].source == VariableSource(kind: .app, workflows: ["Beta"]))
        #expect(effective[0].replaces == [
            VariableSource(kind: .app), VariableSource(kind: .group, group: "Beta only", workflows: ["Beta"]),
            VariableSource(kind: .group, group: "Shared"), VariableSource(kind: .global),
        ])

        // Without the app's own, the global applies once both groups are unlinked.
        try variables.delete(scope: .app(app.id), name: "N", workflows: ["Beta"])
        try variables.delete(scope: .app(app.id), name: "N")
        try variables.unlink(appID: app.id, group: "Shared")
        #expect(try values(variables, app, "Release")["N"] == "global")
    }

    @Test func aGroupLimitedToSomeWorkflowsReachesOnlyThem() throws {
        let (_, variables, app) = try make()
        let sentry = try variables.createGroup(name: "Sentry")
        try variables.set(scope: .group(sentry.id), name: "SENTRY_AUTH_TOKEN", input: VariableInput(value: "t", isSecret: true))
        try variables.link(appID: app.id, group: sentry.id.uuidString, workflows: ["Beta", "Release"])
        #expect(try values(variables, app, "Beta")["SENTRY_AUTH_TOKEN"] == "t")
        #expect(try values(variables, app, "Release")["SENTRY_AUTH_TOKEN"] == "t")
        #expect(try values(variables, app, "CI")["SENTRY_AUTH_TOKEN"] == nil)
        #expect(try values(variables, app, nil)["SENTRY_AUTH_TOKEN"] == nil)

        // Changing the link's workflows keeps its place; unlinking stops it.
        try variables.link(appID: app.id, group: "Sentry", workflows: [])
        #expect(try values(variables, app, "CI")["SENTRY_AUTH_TOKEN"] == "t")
        #expect(try variables.links(appID: app.id).map(\.workflows) == [[]])
        #expect(try variables.group("sentry")?.apps.map(\.slug) == ["legilo"])
    }

    @Test func twoGroupsWithTheSameNameTheFirstLinkedWins() throws {
        let (_, variables, app) = try make()
        for name in ["First", "Second"] {
            let group = try variables.createGroup(name: name)
            try variables.set(scope: .group(group.id), name: "N", input: VariableInput(value: name))
        }
        try variables.link(appID: app.id, group: "Second", workflows: [])
        try variables.link(appID: app.id, group: "First", workflows: [])
        #expect(try variables.links(appID: app.id).map(\.name) == ["Second", "First"])
        #expect(try values(variables, app, "X")["N"] == "Second")
        // Re-linking with other workflows does not move it.
        try variables.link(appID: app.id, group: "Second", workflows: [])
        #expect(try values(variables, app, "X")["N"] == "Second")
        try variables.unlink(appID: app.id, group: "Second")
        try variables.link(appID: app.id, group: "Second", workflows: [])
        #expect(try values(variables, app, "X")["N"] == "First")
    }

    @Test func sameNameForDisjointWorkflowsAndOverlapRefused() throws {
        let (_, variables, app) = try make()
        let scope = VariableScope.app(app.id)
        try variables.set(scope: scope, name: "SENTRY_DSN", input: VariableInput(value: "beta", workflows: ["Beta"]))
        try variables.set(scope: scope, name: "SENTRY_DSN", input: VariableInput(value: "release", workflows: ["Release", "Nightly"]))
        try variables.set(scope: scope, name: "SENTRY_DSN", input: VariableInput(value: "all"))
        #expect(try variables.summaries(scope: scope).map(\.workflows) == [[], ["Beta"], ["Nightly", "Release"]])

        #expect(throws: APIError(
            code: "variable_workflows_overlap",
            message: "SENTRY_DSN is already set for “Release”. A workflow can get only one SENTRY_DSN from the app: edit that one, or choose other workflows."
        )) {
            try variables.set(scope: scope, name: "SENTRY_DSN", input: VariableInput(value: "x", workflows: ["Release", "Staging"]))
        }
        // The same set is a replacement, not an overlap; the order and duplicates do not matter.
        try variables.set(scope: scope, name: "SENTRY_DSN", input: VariableInput(value: "release-2", workflows: ["Nightly", "Release", "Release"]))
        #expect(try values(variables, app, "Nightly")["SENTRY_DSN"] == "release-2")

        // Moving a row: refused onto another's workflows, allowed onto free ones; the value stays.
        #expect(throws: APIError.self) {
            try variables.update(appID: app.id, name: "SENTRY_DSN", workflows: ["Beta"], with: VariableUpdate(workflows: ["Nightly"]))
        }
        #expect(throws: APIError(code: "variable_exists", message: "SENTRY_DSN already has a value for all workflows. Edit that one, or delete it first.")) {
            try variables.update(appID: app.id, name: "SENTRY_DSN", workflows: ["Beta"], with: VariableUpdate(workflows: []))
        }
        try variables.update(appID: app.id, name: "SENTRY_DSN", workflows: ["Beta"], with: VariableUpdate(workflows: ["Beta", "Staging"]))
        #expect(try values(variables, app, "Staging")["SENTRY_DSN"] == "beta")
        try variables.update(
            appID: app.id, name: "SENTRY_DSN", workflows: ["Staging", "Beta"], with: VariableUpdate(value: "beta-2", isSecret: true))
        #expect(try variables.resolvedEntries(appID: app.id, workflow: "Beta").first?.isSecret == true)
        #expect(try values(variables, app, "Beta")["SENTRY_DSN"] == "beta-2")
        #expect(throws: APIError(code: "variable_not_found", message: "No variable SENTRY_DSN for “Gone”.")) {
            try variables.update(appID: app.id, name: "SENTRY_DSN", workflows: ["Gone"], with: VariableUpdate(value: "x"))
        }
    }

    @Test func reservedNamesAndScopesWithoutWorkflows() throws {
        let (_, variables, app) = try make()
        let group = try variables.createGroup(name: "G")
        #expect(throws: APIError(code: "reserved_variable", message: "HANGAR_GITHUB_TOKEN can’t be limited to workflows: Hangar uses it for the whole app.")) {
            try variables.set(scope: .app(app.id), name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "t", workflows: ["Beta"]))
        }
        #expect(throws: APIError(code: "reserved_variable", message: "HANGAR_GITHUB_TOKEN can’t be in a group: set it in Settings or on the app.")) {
            try variables.set(scope: .group(group.id), name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "t"))
        }
        #expect(throws: APIError.self) {
            try variables.set(scope: .global, name: "X", input: VariableInput(value: "t", workflows: ["Beta"]))
        }
        #expect(throws: APIError.self) {
            try variables.set(scope: .group(group.id), name: "X", input: VariableInput(value: "t", workflows: ["Beta"]))
        }
        #expect(throws: APIError(code: "invalid_workflows", message: "A workflow name can’t be empty.")) {
            try variables.set(scope: .app(app.id), name: "X", input: VariableInput(value: "t", workflows: [" "]))
        }
        // The app-wide token is still allowed, as before.
        try variables.set(scope: .app(app.id), name: "HANGAR_GITHUB_TOKEN", input: VariableInput(value: "t", isSecret: true))
    }

    @Test func groupsAreNamedOnceAndGoWithTheirVariablesAndLinks() throws {
        let (database, variables, app) = try make()
        let group = try variables.createGroup(name: "  Sentry ")
        #expect(group.name == "Sentry")
        #expect(throws: APIError(code: "variable_group_exists", message: "A variable group named “sentry” already exists.")) {
            try variables.createGroup(name: "sentry")
        }
        #expect(throws: APIError.self) { try variables.createGroup(name: "") }
        #expect(try variables.renameGroup("Sentry", to: "SENTRY").name == "SENTRY")  // its own name in another case
        try variables.set(scope: .group(group.id), name: "SENTRY_ORG", input: VariableInput(value: "acme"))
        try variables.link(appID: app.id, group: "SENTRY", workflows: [])
        #expect(try variables.groups().map(\.variables.count) == [1])

        try variables.deleteGroup("sentry")
        #expect(try variables.groups().isEmpty)
        #expect(try variables.links(appID: app.id).isEmpty)
        let left = try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM variables") }
        #expect(left == 0)
        #expect(throws: APIError(code: "variable_group_not_found", message: "No variable group 'sentry'.")) {
            try variables.link(appID: app.id, group: "sentry", workflows: [])
        }

        // Deleting the app removes its links.
        let other = try variables.createGroup(name: "Other")
        try variables.link(appID: app.id, group: "Other", workflows: ["Beta"])
        try AppRepository(database: database).delete(id: app.id)
        #expect(try variables.group("Other")?.apps.isEmpty == true)
        #expect(other.apps.isEmpty)
    }
}

/// The routes, with and without API tokens; values never come back.
@Suite(.timeLimit(.minutes(1))) struct VariableScopesAPITests {
    private func bearer(_ secret: String, json: Bool = false) -> HTTPFields {
        var fields: HTTPFields = [.authorization: "Bearer \(secret)"]
        if json { fields[.contentType] = "application/json" }
        return fields
    }

    @Test func groupsLinksAndWorkflowVariablesThroughTheAPI() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        let secret = "s3cr3t-dsn-value-77"
        try await fixture.test { client in
            let created = try await client.execute(
                uri: "/api/v1/variable-groups", method: .post, headers: jsonHeaders, body: try body(VariableGroupRequest(name: "Sentry"))
            ) { response throws in
                #expect(response.status == .created)
                return try decode(VariableGroup.self, response)
            }
            try await client.execute(
                uri: "/api/v1/variable-groups/Sentry/variables/SENTRY_AUTH_TOKEN", method: .put, headers: jsonHeaders,
                body: try body(VariableInput(value: secret, isSecret: true))
            ) { #expect($0.status == .noContent) }
            try await client.execute(
                uri: "/api/v1/apps/legilo/variable-groups/\(created.id.uuidString)", method: .put, headers: jsonHeaders,
                body: try body(LinkVariableGroupRequest(workflows: ["testflight"]))
            ) { #expect($0.status == .noContent) }
            try await client.execute(
                uri: "/api/v1/apps/legilo/variables/SENTRY_DSN", method: .put, headers: jsonHeaders,
                body: try body(VariableInput(value: secret, isSecret: true, workflows: ["UX Review"]))
            ) { #expect($0.status == .noContent) }
            try await client.execute(
                uri: "/api/v1/apps/legilo/variables/SENTRY_DSN", method: .put, headers: jsonHeaders,
                body: try body(VariableInput(value: "x", workflows: ["UX Review", "beta"]))
            ) { response throws in
                #expect(response.status == .conflict)
                #expect(try decode(APIError.self, response).code == "variable_workflows_overlap")
                #expect(!String(buffer: response.body).contains(secret))
            }
            // PATCH and DELETE name the row by its workflows; the form encoding's `+` is a space.
            try await client.execute(
                uri: "/api/v1/apps/legilo/variables/SENTRY_DSN?workflow=UX+Review", method: .patch, headers: jsonHeaders,
                body: try body(VariableUpdate(workflows: ["UX Review", "beta"]))
            ) { #expect($0.status == .noContent) }
            try await client.execute(uri: "/api/v1/apps/legilo/variables/SENTRY_DSN?workflow=Gone", method: .patch, headers: jsonHeaders,
                body: try body(VariableUpdate(value: "y"))
            ) { #expect($0.status == .notFound) }

            for uri in [
                "/api/v1/variable-groups", "/api/v1/variable-groups/sentry", "/api/v1/apps/legilo/variable-groups",
                "/api/v1/apps/legilo/variables", "/api/v1/apps/legilo/environment?workflow=testflight",
            ] {
                try await client.execute(uri: uri, method: .get) { response throws in
                    #expect(response.status == .ok, "\(uri)")
                    #expect(!String(buffer: response.body).contains(secret), "\(uri)")
                }
            }
            let summaries = try await client.execute(uri: "/api/v1/apps/legilo/variables", method: .get) {
                try decode([VariableSummary].self, $0)
            }
            #expect(summaries.map(\.workflows) == [["UX Review", "beta"]])
            let environment = try await client.execute(uri: "/api/v1/apps/legilo/environment?workflow=beta", method: .get) {
                try decode([EffectiveVariable].self, $0)
            }
            #expect(environment.map(\.name) == ["SENTRY_DSN"])
            let testflight = try await client.execute(uri: "/api/v1/apps/legilo/environment?workflow=testflight", method: .get) {
                try decode([EffectiveVariable].self, $0)
            }
            #expect(testflight.map(\.source) == [VariableSource(kind: .group, group: "Sentry", workflows: ["testflight"])])
            let groups = try await client.execute(uri: "/api/v1/variable-groups", method: .get) { try decode([VariableGroup].self, $0) }
            #expect(groups.first?.apps.map(\.workflows) == [["testflight"]])

            try await client.execute(
                uri: "/api/v1/apps/legilo/variables/SENTRY_DSN?workflow=UX%20Review&workflow=beta", method: .delete
            ) { #expect($0.status == .noContent) }
            try await client.execute(uri: "/api/v1/apps/legilo/variable-groups/sentry", method: .delete) { #expect($0.status == .noContent) }
            try await client.execute(
                uri: "/api/v1/variable-groups/sentry", method: .patch, headers: jsonHeaders, body: try body(VariableGroupRequest(name: "Crash Reports"))
            ) { response throws in
                #expect(try decode(VariableGroup.self, response).name == "Crash Reports")
            }
            try await client.execute(uri: "/api/v1/variable-groups/Crash%20Reports", method: .delete) { #expect($0.status == .noContent) }
            try await client.execute(uri: "/api/v1/variable-groups/sentry", method: .get) { response throws in
                #expect(response.status == .notFound)
                #expect(try decode(APIError.self, response).code == "variable_group_not_found")
            }
        }
        #expect(try fixture.server.variables.summaries(scope: .app(fixture.server.apps.find(slugOrID: "legilo")!.id)).isEmpty)
    }

    @Test func tokensReadNamesButNeverChangeGroupsOrVariables() async throws {
        let fixture = try APIFixture()
        try fixture.createApp()
        let group = try fixture.server.variables.createGroup(name: "Sentry")
        let read = try fixture.server.apiTokens.create(name: "r", scope: .read).secret
        let configure = try fixture.server.apiTokens.create(name: "c", scope: .configure).secret
        try await fixture.test { client in
            for uri in ["/api/v1/variable-groups", "/api/v1/apps/legilo/variable-groups", "/api/v1/apps/legilo/environment?workflow=beta"] {
                try await client.execute(uri: uri, method: .get, headers: bearer(read)) { #expect($0.status == .ok, "\(uri)") }
            }
            let refused: [(HTTPRequest.Method, String, ByteBuffer?)] = [
                (.post, "/api/v1/variable-groups", try body(VariableGroupRequest(name: "More"))),
                (.patch, "/api/v1/variable-groups/Sentry", try body(VariableGroupRequest(name: "X"))),
                (.delete, "/api/v1/variable-groups/Sentry", nil),
                (.put, "/api/v1/variable-groups/Sentry/variables/X", try body(VariableInput(value: "v"))),
                (.delete, "/api/v1/variable-groups/Sentry/variables/X", nil),
                (.put, "/api/v1/apps/legilo/variable-groups/Sentry", try body(LinkVariableGroupRequest())),
                (.delete, "/api/v1/apps/legilo/variable-groups/Sentry", nil),
                (.patch, "/api/v1/apps/legilo/variables/X", try body(VariableUpdate(workflows: []))),
            ]
            for (method, uri, payload) in refused {
                try await client.execute(uri: uri, method: method, headers: bearer(configure, json: payload != nil), body: payload) {
                    response throws in
                    #expect(response.status == .forbidden, "\(method) \(uri)")
                    #expect(try decode(APIError.self, response).code == "token_scope")
                }
            }
        }
        #expect(try fixture.server.variables.groups().map(\.id) == [group.id])
    }
}
