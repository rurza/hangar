import Foundation
import GRDB

/// The workflow file an app has defined in Hangar (at most one per app); the text is stored as given.
public struct WorkflowFileRepository: Sendable {
    let database: Database

    public init(database: Database) { self.database = database }

    public func get(appID: UUID) throws -> (yaml: String, updatedAt: Date)? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT yaml, updated_at FROM app_workflows WHERE app_id = ?", arguments: [appID.uuidString])
                .map { (yaml: $0["yaml"] as String, updatedAt: dbDate($0["updated_at"] as Double)) }
        }
    }

    public func set(appID: UUID, yaml: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_workflows (app_id, yaml, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(app_id) DO UPDATE SET yaml = excluded.yaml, updated_at = excluded.updated_at
                    """,
                arguments: [appID.uuidString, yaml, dbTime(Date())])
        }
    }

    public func delete(appID: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM app_workflows WHERE app_id = ?", arguments: [appID.uuidString])
        }
    }
}
