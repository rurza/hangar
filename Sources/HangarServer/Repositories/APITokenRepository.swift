import CryptoKit
import Foundation
import GRDB
import HangarCore

/// API tokens for agents. The secret is returned once by `create`; only its SHA-256 hex is stored.
public struct APITokenRepository: Sendable {
    let database: Database
    /// How stale `last_used_at` may get before a request updates it, so every request is not a write.
    static let lastUsedResolution: TimeInterval = 60

    public init(database: Database) { self.database = database }

    public func create(name: String, scope: APITokenScope, now: Date = Date()) throws -> (APIToken, secret: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else {
            throw APIError(code: "invalid_name", message: "A token needs a name of 1 to 64 characters.")
        }
        let secret = APIToken.secretPrefix + Self.base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        let token = APIToken(
            id: UUID(), name: trimmed, scope: scope, prefix: String(secret.prefix(APIToken.secretPrefix.count + 4)),
            createdAt: Date(timeIntervalSince1970: dbTime(now)))
        let exists = APIError(code: "token_exists", message: "A token named '\(trimmed)' already exists.")
        do {
            try database.write { db in
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM api_tokens WHERE name = ?)", arguments: [trimmed]) == true {
                    throw exists
                }
                try db.execute(
                    sql: """
                        INSERT INTO api_tokens (id, name, scope, prefix, token_hash, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        token.id.uuidString, token.name, token.scope.rawValue, token.prefix, Self.hash(secret),
                        dbTime(token.createdAt),
                    ])
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw exists
        }
        return (token, secret)
    }

    /// The token whose secret this is, nil when none; records the use (at most once a minute).
    public func authenticate(secret: String, now: Date = Date()) throws -> APIToken? {
        guard APIToken.isWellFormedSecret(secret) else { return nil }
        return try database.write { db in
            guard var token = try Row.fetchOne(
                db, sql: "SELECT * FROM api_tokens WHERE token_hash = ?", arguments: [Self.hash(secret)]
            ).map(Self.token) else { return nil }
            if token.lastUsedAt.map({ now.timeIntervalSince($0) >= Self.lastUsedResolution }) ?? true {
                try db.execute(
                    sql: "UPDATE api_tokens SET last_used_at = ? WHERE id = ?", arguments: [dbTime(now), token.id.uuidString])
                token.lastUsedAt = Date(timeIntervalSince1970: dbTime(now))
            }
            return token
        }
    }

    public func all() throws -> [APIToken] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM api_tokens ORDER BY name COLLATE NOCASE").map(Self.token)
        }
    }

    public func find(nameOrID: String) throws -> APIToken? {
        try database.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM api_tokens WHERE name = ? OR id = ?", arguments: [nameOrID, nameOrID.uppercased()]
            ).map(Self.token)
        }
    }

    public func delete(id: UUID) throws {
        try database.write { db in try db.execute(sql: "DELETE FROM api_tokens WHERE id = ?", arguments: [id.uuidString]) }
    }

    private static func hash(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func token(_ row: Row) throws -> APIToken {
        APIToken(
            id: UUID(uuidString: row["id"])!, name: row["name"],
            scope: APITokenScope(rawValue: row["scope"]) ?? .read, prefix: row["prefix"],
            createdAt: dbDate(row["created_at"] as Double), lastUsedAt: dbDate(row["last_used_at"] as Double?))
    }
}
