import Foundation
import GRDB
import HangarCore

public struct AppRepository: Sendable {
    let database: Database

    public init(database: Database) { self.database = database }

    public func inTransaction<T>(_ body: (GRDB.Database) throws -> T) throws -> T {
        try database.write(body)
    }

    public func create(_ request: CreateAppRequest) throws -> App {
        let slug = App.slug(for: request.name)
        guard !slug.isEmpty else {
            throw APIError(code: "invalid_name", message: "The app name needs at least one letter or digit.")
        }
        let app = App(
            id: UUID(), slug: slug, name: request.name, repoURL: request.repoURL,
            appStoreConnectAppID: request.appStoreConnectAppID, iconURL: request.iconURL,
            createdAt: Date(timeIntervalSince1970: dbTime(Date())))
        return try database.write { db in
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM apps WHERE slug = ?)", arguments: [slug]) == true {
                throw APIError(code: "app_exists", message: "An app with the slug '\(slug)' already exists.")
            }
            try db.execute(
                sql: """
                    INSERT INTO apps (id, slug, name, repo_url, app_store_connect_app_id, icon_url, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    app.id.uuidString, app.slug, app.name, app.repoURL, app.appStoreConnectAppID, app.iconURL,
                    dbTime(app.createdAt),
                ])
            return app
        }
    }

    public func all() throws -> [App] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM apps ORDER BY name, slug").map(Self.app)
        }
    }

    public func find(slugOrID: String) throws -> App? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM apps WHERE slug = ? OR id = ?", arguments: [slugOrID, slugOrID.uppercased()])
                .map(Self.app)
        }
    }

    /// Removes the app with its builds, jobs, numbers and variables.
    public func delete(id: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM variables WHERE scope = 'app' AND app_id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM apps WHERE id = ?", arguments: [id.uuidString])
        }
    }

    static func app(_ row: Row) -> App {
        App(
            id: UUID(uuidString: row["id"])!, slug: row["slug"], name: row["name"], repoURL: row["repo_url"],
            appStoreConnectAppID: row["app_store_connect_app_id"], iconURL: row["icon_url"],
            createdAt: dbDate(row["created_at"] as Double))
    }
}
