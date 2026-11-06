import Foundation
import GRDB
import HangarCore

/// Global, group and app variables, and the groups apps link (variable scopes design). Every value is sealed, plain
/// or secret; `isSecret` only governs what the API shows later. Nothing here returns a value except
/// `resolvedEntries`, which only the job assignment and the server's own GitHub calls use.
///
/// A job of workflow W gets, for each name, the first of: an app variable limited to W, the app variable for all
/// workflows, a linked group limited to W, a linked group for all workflows, a global variable. Between two groups
/// at the same level the one linked first (listed higher) wins.
public struct VariableRepository: Sendable {
    let database: Database
    let box: SecretBox

    public init(database: Database, box: SecretBox) {
        self.database = database
        self.box = box
    }

    public func inTransaction<T>(_ body: (GRDB.Database) throws -> T) throws -> T { try database.write(body) }

    // MARK: Variables

    /// Sets the variable `name` of `scope` for exactly `input.workflows` (app variables only; empty means all
    /// workflows), replacing that one if it exists. A new restricted app variable must not share a workflow with
    /// another of the same name.
    public func set(scope: VariableScope, name: String, input: VariableInput) throws {
        try Self.validate(name: name)
        let workflows = try Self.normalized(input.workflows)
        try Self.check(scope: scope, name: name, workflows: workflows)
        let sealed = try box.seal(input.value)
        let (kind, owner) = Self.columns(scope)
        let key = Self.key(workflows)
        try database.write { db in
            if try Self.row(db, kind, owner, name, key) == nil {
                try Self.checkOverlap(db, kind, owner, name, workflows, excluding: nil)
            }
            try db.execute(
                sql: """
                    INSERT INTO variables (id, scope, owner_id, name, workflows, ciphertext, is_secret, as_file, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (scope, owner_id, name, workflows) DO UPDATE SET
                        ciphertext = excluded.ciphertext, is_secret = excluded.is_secret,
                        as_file = excluded.as_file, updated_at = excluded.updated_at
                    """,
                arguments: [UUID().uuidString, kind, owner, name, key, sealed, input.isSecret, input.asFile, dbTime(Date())])
        }
    }

    /// Changes the app variable `name` limited to `workflows` (empty: the one for all workflows): its workflows,
    /// value or flags, whichever `update` has.
    public func update(appID: UUID, name: String, workflows: [String], with update: VariableUpdate) throws {
        let scope = VariableScope.app(appID)
        let current = try Self.normalized(workflows)
        let target = try update.workflows.map(Self.normalized) ?? current
        try Self.check(scope: scope, name: name, workflows: target)
        let sealed = try update.value.map(box.seal)
        let (kind, owner) = Self.columns(scope)
        try database.write { db in
            guard let id = try Self.row(db, kind, owner, name, Self.key(current)) else {
                throw APIError(code: "variable_not_found", message: "No variable \(name) \(Self.coverage(current)).")
            }
            if target != current {
                if try Self.row(db, kind, owner, name, Self.key(target)) != nil, target.isEmpty {
                    throw APIError(
                        code: "variable_exists",
                        message: "\(name) already has a value for all workflows. Edit that one, or delete it first.")
                }
                try Self.checkOverlap(db, kind, owner, name, target, excluding: id)
            }
            var assignments = ["workflows = ?", "updated_at = ?"]
            var arguments: StatementArguments = [Self.key(target), dbTime(Date())]
            if let sealed { assignments.append("ciphertext = ?"); arguments += [sealed] }
            if let isSecret = update.isSecret { assignments.append("is_secret = ?"); arguments += [isSecret] }
            if let asFile = update.asFile { assignments.append("as_file = ?"); arguments += [asFile] }
            arguments += [id]
            try db.execute(sql: "UPDATE variables SET \(assignments.joined(separator: ", ")) WHERE id = ?", arguments: arguments)
        }
    }

    /// Deletes the variable `name` of `scope` limited to exactly `workflows` (empty: the one for all workflows).
    public func delete(scope: VariableScope, name: String, workflows: [String] = []) throws {
        let (kind, owner) = Self.columns(scope)
        let key = Self.key(try Self.normalized(workflows))
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM variables WHERE scope = ? AND owner_id = ? AND name = ? AND workflows = ?",
                arguments: [kind, owner, name, key])
        }
    }

    /// By name; one for all workflows before the restricted ones.
    public func summaries(scope: VariableScope) throws -> [VariableSummary] {
        let (kind, owner) = Self.columns(scope)
        return try database.read { db in try Self.summaries(db, kind: kind, owner: owner, scope: scope) }
    }

    public func value(global name: String) throws -> String? {
        let sealed = try database.read { db in
            try Data.fetchOne(
                db, sql: "SELECT ciphertext FROM variables WHERE scope = 'global' AND owner_id = '' AND name = ?",
                arguments: [name])
        }
        return try sealed.map(box.open)
    }

    // MARK: Resolution

    /// What a job of `workflow` gets, with values. Without a workflow (the server's own GitHub calls, the scheduler's
    /// team-key check) only what applies to every workflow counts.
    public func resolvedEntries(appID: UUID, workflow: String?) throws -> [EnvEntry] {
        try database.read { db in try Self.layers(db, appID: appID, workflow: workflow) }
            .compactMap { candidates in
                guard let winner = candidates.first else { return nil }
                return EnvEntry(
                    name: winner.name, value: try box.open(winner.ciphertext), isSecret: winner.isSecret,
                    asFile: winner.asFile)
            }
    }

    /// What a job of `workflow` gets, without values: each name's source and what it replaces.
    public func effective(appID: UUID, workflow: String?) throws -> [EffectiveVariable] {
        try database.read { db in try Self.layers(db, appID: appID, workflow: workflow) }.compactMap { candidates in
            guard let winner = candidates.first else { return nil }
            return EffectiveVariable(
                name: winner.name, isSecret: winner.isSecret, asFile: winner.asFile, source: winner.source,
                replaces: candidates.dropFirst().map(\.source))
        }
    }

    /// For each name, every variable that could give a job of `workflow` its value, the winner first; sorted by name.
    private static func layers(_ db: GRDB.Database, appID: UUID, workflow: String?) throws -> [[Candidate]] {
        let app = appID.uuidString
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT v.scope, v.name, v.workflows, v.ciphertext, v.is_secret, v.as_file,
                       NULL AS link_workflows, NULL AS position, NULL AS group_name
                FROM variables v
                WHERE v.scope = 'global' OR (v.scope = 'app' AND v.owner_id = ?)
                UNION ALL
                SELECT v.scope, v.name, v.workflows, v.ciphertext, v.is_secret, v.as_file,
                       l.workflows AS link_workflows, l.position AS position, g.name AS group_name
                FROM app_variable_groups l
                JOIN variable_groups g ON g.id = l.group_id
                JOIN variables v ON v.scope = 'group' AND v.owner_id = l.group_id
                WHERE l.app_id = ?
                """,
            arguments: [app, app])
        var byName: [String: [(rank: Int, position: Int, candidate: Candidate)]] = [:]
        for row in rows {
            let scope: String = row["scope"]
            let own = Self.workflows(row["workflows"])
            let link = Self.workflows(row["link_workflows"] as String? ?? "")
            // 0 app for W, 1 app for all, 2 group for W, 3 group for all, 4 global; nil when it does not apply.
            let rank: Int?
            let source: VariableSource
            switch scope {
            case "app":
                rank = own.isEmpty ? 1 : (workflow.map(own.contains) == true ? 0 : nil)
                source = VariableSource(kind: .app, workflows: own)
            case "group":
                rank = link.isEmpty ? 3 : (workflow.map(link.contains) == true ? 2 : nil)
                source = VariableSource(kind: .group, group: row["group_name"], workflows: link)
            default:
                rank = 4
                source = VariableSource(kind: .global)
            }
            let name: String = row["name"]
            // Never resolved, even if such a row were left: the key is a setting (migration v11 deleted them).
            guard let rank, !name.hasPrefix(Self.appStoreConnectPrefix) else { continue }
            byName[name, default: []].append((
                rank, row["position"] as Int? ?? 0,
                Candidate(
                    name: name, ciphertext: row["ciphertext"], isSecret: row["is_secret"], asFile: row["as_file"],
                    source: source)))
        }
        return byName.keys.sorted().map { name in
            byName[name, default: []].sorted { ($0.rank, $0.position) < ($1.rank, $1.position) }.map(\.candidate)
        }
    }

    private struct Candidate {
        var name: String
        var ciphertext: Data
        var isSecret: Bool
        var asFile: Bool
        var source: VariableSource
    }

    // MARK: Groups

    public func groups() throws -> [VariableGroup] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, created_at FROM variable_groups ORDER BY name COLLATE NOCASE")
                .map { try Self.group(db, $0) }
        }
    }

    /// The group with the id or the name `key` (any case).
    public func group(_ key: String) throws -> VariableGroup? {
        try database.read { db in
            try Self.groupRow(db, key).map { try Self.group(db, $0) }
        }
    }

    public func createGroup(name: String, now: Date = Date()) throws -> VariableGroup {
        let name = try Self.groupName(name)
        let id = UUID()
        try database.write { db in
            try Self.checkGroupNameFree(db, name, except: nil)
            try db.execute(
                sql: "INSERT INTO variable_groups (id, name, created_at) VALUES (?, ?, ?)",
                arguments: [id.uuidString, name, dbTime(now)])
        }
        return try requireGroup(id.uuidString)
    }

    public func renameGroup(_ key: String, to name: String) throws -> VariableGroup {
        let name = try Self.groupName(name)
        let id = try requireGroup(key).id
        try database.write { db in
            try Self.checkGroupNameFree(db, name, except: id)
            try db.execute(sql: "UPDATE variable_groups SET name = ? WHERE id = ?", arguments: [name, id.uuidString])
        }
        return try requireGroup(id.uuidString)
    }

    /// Deletes the group, its variables and every app's link to it.
    public func deleteGroup(_ key: String) throws {
        let id = try requireGroup(key).id.uuidString
        try database.write { db in
            try db.execute(sql: "DELETE FROM variables WHERE scope = 'group' AND owner_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM variable_groups WHERE id = ?", arguments: [id])
        }
    }

    public func requireGroup(_ key: String) throws -> VariableGroup {
        guard let group = try group(key) else {
            throw APIError(code: "variable_group_not_found", message: "No variable group '\(key)'.")
        }
        return group
    }

    // MARK: Links

    /// The groups `appID` links, in precedence order (the first wins a name two share).
    public func links(appID: UUID) throws -> [AppVariableGroupLink] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT g.id, g.name, l.workflows FROM app_variable_groups l
                    JOIN variable_groups g ON g.id = l.group_id
                    WHERE l.app_id = ? ORDER BY l.position
                    """,
                arguments: [appID.uuidString]
            ).map { row in
                let id = UUID(uuidString: row["id"])!
                return AppVariableGroupLink(
                    groupID: id, name: row["name"], workflows: Self.workflows(row["workflows"]),
                    variables: try Self.summaries(db, kind: "group", owner: id.uuidString, scope: .group(id)))
            }
        }
    }

    /// Links the group for `workflows` (empty: all), or changes an existing link's workflows; it keeps its place.
    public func link(appID: UUID, group key: String, workflows: [String]) throws {
        let group = try requireGroup(key)
        let key = Self.key(try Self.normalized(workflows))
        try database.write { db in
            let next = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM app_variable_groups WHERE app_id = ?",
                arguments: [appID.uuidString]) ?? 0
            try db.execute(
                sql: """
                    INSERT INTO app_variable_groups (app_id, group_id, workflows, position) VALUES (?, ?, ?, ?)
                    ON CONFLICT (app_id, group_id) DO UPDATE SET workflows = excluded.workflows
                    """,
                arguments: [appID.uuidString, group.id.uuidString, key, next])
        }
    }

    public func unlink(appID: UUID, group key: String) throws {
        let group = try requireGroup(key)
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM app_variable_groups WHERE app_id = ? AND group_id = ?",
                arguments: [appID.uuidString, group.id.uuidString])
        }
    }

    // MARK: Rules

    static func validate(name: String) throws {
        guard name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else {
            throw APIError(code: "invalid_variable_name", message: "'\(name)' is not a valid variable name.")
        }
    }

    /// The App Store Connect key's old variable names (`HANGAR_ASC_KEY_ID` and so on): the key is a server setting now.
    static let appStoreConnectPrefix = "HANGAR_ASC_"

    /// The server reads `HANGAR_*` names without a workflow, so they apply to all workflows and are never in a group.
    static func check(scope: VariableScope, name: String, workflows: [String]) throws {
        switch scope {
        case .global, .group:
            guard workflows.isEmpty else {
                throw APIError(
                    code: "invalid_workflows",
                    message: "Only app variables can be limited to workflows; link a group for some workflows instead.")
            }
        case .app:
            break
        }
        guard name.hasPrefix("HANGAR_") else { return }
        if name.hasPrefix(Self.appStoreConnectPrefix) {
            throw APIError(
                code: "reserved_variable",
                message: "\(name) is not a variable: set the App Store Connect key in Settings › App Store Connect. Jobs never get it in their environment.")
        }
        if case .group = scope {
            throw APIError(
                code: "reserved_variable", message: "\(name) can’t be in a group: set it in Settings or on the app.")
        }
        if !workflows.isEmpty {
            throw APIError(
                code: "reserved_variable", message: "\(name) can’t be limited to workflows: Hangar uses it for the whole app.")
        }
    }

    /// Trimmed, without duplicates, sorted; each name non-empty and at most 100 characters, at most 50 names.
    static func normalized(_ workflows: [String]) throws -> [String] {
        let names = workflows.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if names.contains(where: \.isEmpty) {
            throw APIError(code: "invalid_workflows", message: "A workflow name can’t be empty.")
        }
        if let long = names.first(where: { $0.count > 100 }) {
            throw APIError(code: "invalid_workflows", message: "“\(long.prefix(40))…” is too long for a workflow name.")
        }
        let unique = Array(Set(names)).sorted()
        guard unique.count <= 50 else {
            throw APIError(code: "invalid_workflows", message: "A variable can be limited to at most 50 workflows.")
        }
        return unique
    }

    /// A restricted variable must not share a workflow with another restricted one of the same name.
    private static func checkOverlap(
        _ db: GRDB.Database, _ kind: String, _ owner: String, _ name: String, _ workflows: [String], excluding id: String?
    ) throws {
        guard !workflows.isEmpty else { return }
        let others = try Row.fetchAll(
            db, sql: "SELECT id, workflows FROM variables WHERE scope = ? AND owner_id = ? AND name = ? AND workflows <> ''",
            arguments: [kind, owner, name])
        for other in others where (other["id"] as String) != id {
            let shared = Set(Self.workflows(other["workflows"])).intersection(workflows).sorted()
            guard !shared.isEmpty else { continue }
            throw APIError(
                code: "variable_workflows_overlap",
                message: "\(name) is already set \(coverage(shared)). A workflow can get only one \(name) from the app: edit that one, or choose other workflows.")
        }
    }

    /// "for all workflows", "for “Beta”", "for “Beta” and “Release”".
    static func coverage(_ workflows: [String]) -> String {
        guard !workflows.isEmpty else { return "for all workflows" }
        let quoted = workflows.map { "“\($0)”" }
        return "for " + (quoted.count == 1 ? quoted[0] : quoted.dropLast().joined(separator: ", ") + " and " + quoted.last!)
    }

    static func groupName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(trimmed.count), !trimmed.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true })
        else {
            throw APIError(code: "invalid_name", message: "A group name needs 1 to 64 characters on one line.")
        }
        return trimmed
    }

    private static func checkGroupNameFree(_ db: GRDB.Database, _ name: String, except id: UUID?) throws {
        let taken = try String.fetchOne(
            db, sql: "SELECT id FROM variable_groups WHERE name = ? COLLATE NOCASE", arguments: [name])
        if let taken, taken != id?.uuidString {
            throw APIError(code: "variable_group_exists", message: "A variable group named “\(name)” already exists.")
        }
    }

    // MARK: Rows

    private static func row(_ db: GRDB.Database, _ kind: String, _ owner: String, _ name: String, _ key: String) throws -> String? {
        try String.fetchOne(
            db, sql: "SELECT id FROM variables WHERE scope = ? AND owner_id = ? AND name = ? AND workflows = ?",
            arguments: [kind, owner, name, key])
    }

    private static func summaries(_ db: GRDB.Database, kind: String, owner: String, scope: VariableScope) throws -> [VariableSummary] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT name, workflows, is_secret, as_file, updated_at FROM variables
                WHERE scope = ? AND owner_id = ? ORDER BY name, workflows
                """,
            arguments: [kind, owner]
        ).map {
            VariableSummary(
                scope: scope, name: $0["name"], isSecret: $0["is_secret"], asFile: $0["as_file"],
                workflows: Self.workflows($0["workflows"]), updatedAt: dbDate($0["updated_at"] as Double))
        }
    }

    private static func groupRow(_ db: GRDB.Database, _ key: String) throws -> Row? {
        if let id = UUID(uuidString: key),
            let row = try Row.fetchOne(db, sql: "SELECT id, name, created_at FROM variable_groups WHERE id = ?", arguments: [id.uuidString])
        {
            return row
        }
        return try Row.fetchOne(
            db, sql: "SELECT id, name, created_at FROM variable_groups WHERE name = ? COLLATE NOCASE", arguments: [key])
    }

    private static func group(_ db: GRDB.Database, _ row: Row) throws -> VariableGroup {
        let id = UUID(uuidString: row["id"])!
        let apps = try Row.fetchAll(
            db,
            sql: """
                SELECT a.id, a.slug, a.name, l.workflows FROM app_variable_groups l JOIN apps a ON a.id = l.app_id
                WHERE l.group_id = ? ORDER BY a.name COLLATE NOCASE
                """,
            arguments: [id.uuidString]
        ).map {
            VariableGroupUse(
                appID: UUID(uuidString: $0["id"])!, slug: $0["slug"], name: $0["name"], workflows: Self.workflows($0["workflows"]))
        }
        return VariableGroup(
            id: id, name: row["name"], createdAt: dbDate(row["created_at"] as Double),
            variables: try summaries(db, kind: "group", owner: id.uuidString, scope: .group(id)), apps: apps)
    }

    /// The `workflows` column: '' for all workflows, else a sorted JSON array.
    static func key(_ workflows: [String]) -> String {
        guard !workflows.isEmpty, let data = try? JSONEncoder().encode(workflows) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func workflows(_ key: String) -> [String] {
        guard !key.isEmpty else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(key.utf8))) ?? []
    }

    private static func columns(_ scope: VariableScope) -> (String, String) {
        switch scope {
        case .global: ("global", "")
        case .app(let id): ("app", id.uuidString)
        case .group(let id): ("group", id.uuidString)
        }
    }
}
