import Foundation
import GRDB

/// Server-wide key-value settings that are not variables: jobs never see them and they hold no secrets.
public struct ServerSettingsRepository: Sendable {
    let database: Database

    public init(database: Database) { self.database = database }

    public func value(_ key: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM server_settings WHERE key = ?", arguments: [key])
        }
    }

    public func set(_ key: String, _ value: String?) throws {
        try database.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO server_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM server_settings WHERE key = ?", arguments: [key])
            }
        }
    }
}
