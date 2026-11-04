import Foundation
import GRDB
import HangarCore

public struct VariableRepository: Sendable {
    let database: Database
    let box: SecretBox

    public init(database: Database, box: SecretBox) {
        self.database = database
        self.box = box
    }

    public func inTransaction<T>(_ body: (GRDB.Database) throws -> T) throws -> T { try database.write(body) }

    /// Every value is sealed, plain or secret; `isSecret` only governs what the API shows later.
    public func set(scope: VariableScope, name: String, input: VariableInput) throws {
        guard name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else {
            throw APIError(code: "invalid_variable_name", message: "'\(name)' is not a valid variable name.")
        }
        let sealed = try box.seal(input.value)
        let (kind, appID) = Self.columns(scope)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO variables (scope, app_id, name, ciphertext, is_secret, as_file, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (scope, app_id, name) DO UPDATE SET
                        ciphertext = excluded.ciphertext, is_secret = excluded.is_secret,
                        as_file = excluded.as_file, updated_at = excluded.updated_at
                    """,
                arguments: [kind, appID, name, sealed, input.isSecret, input.asFile, dbTime(Date())])
        }
    }

    public func delete(scope: VariableScope, name: String) throws {
        let (kind, appID) = Self.columns(scope)
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM variables WHERE scope = ? AND app_id = ? AND name = ?",
                arguments: [kind, appID, name])
        }
    }

    public func summaries(scope: VariableScope) throws -> [VariableSummary] {
        let (kind, appID) = Self.columns(scope)
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT name, is_secret, as_file, updated_at FROM variables
                    WHERE scope = ? AND app_id = ? ORDER BY name
                    """,
                arguments: [kind, appID]
            ).map {
                VariableSummary(
                    scope: scope, name: $0["name"], isSecret: $0["is_secret"], asFile: $0["as_file"],
                    updatedAt: dbDate($0["updated_at"] as Double))
            }
        }
    }

    /// Global variables, then the app's; an app variable replaces a global of the same name. Values are decrypted.
    public func resolvedEntries(appID: UUID) throws -> [EnvEntry] {
        let rows = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT scope, name, ciphertext, is_secret, as_file FROM variables
                    WHERE scope = 'global' OR (scope = 'app' AND app_id = ?)
                    ORDER BY name
                    """,
                arguments: [appID.uuidString])
        }
        var byName: [String: EnvEntry] = [:]
        for row in rows.sorted(by: { ($0["scope"] as String) > ($1["scope"] as String) }) {  // "global" before "app"
            let name: String = row["name"]
            byName[name] = EnvEntry(
                name: name, value: try box.open(row["ciphertext"]), isSecret: row["is_secret"], asFile: row["as_file"])
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    public func value(global name: String) throws -> String? {
        let sealed = try database.read { db in
            try Data.fetchOne(
                db, sql: "SELECT ciphertext FROM variables WHERE scope = 'global' AND app_id = '' AND name = ?",
                arguments: [name])
        }
        return try sealed.map(box.open)
    }

    private static func columns(_ scope: VariableScope) -> (String, String) {
        switch scope {
        case .global: ("global", "")
        case .app(let id): ("app", id.uuidString)
        }
    }
}
