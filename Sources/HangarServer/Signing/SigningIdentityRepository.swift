import Foundation
import GRDB
import HangarCore

/// The server's one signing identity, sealed with the master key like a secret variable: the `.p12` (as base64) and
/// its password each in their own sealed blob. Only `identity()` opens them, for a VM archive's assignment.
public struct SigningIdentityRepository: Sendable {
    let database: Database
    let box: SecretBox

    public init(database: Database, box: SecretBox) {
        self.database = database
        self.box = box
    }

    /// What the identity says about itself; nil when there is none.
    public func info() throws -> SigningIdentityInfo? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM signing_identity WHERE id = 1").map(Self.info)
        }
    }

    /// The `.p12` and its password; nil when there is none.
    public func identity() throws -> JobSigningIdentity? {
        guard let row = try database.read({ db in
            try Row.fetchOne(db, sql: "SELECT sealed_p12, sealed_password FROM signing_identity WHERE id = 1")
        }) else { return nil }
        guard let p12 = Data(base64Encoded: try box.open(row["sealed_p12"] as Data)) else {
            throw SigningCryptoError.failed("read the stored identity")
        }
        return JobSigningIdentity(p12: p12, password: try box.open(row["sealed_password"] as Data))
    }

    /// Stores `identity`, replacing the one there was.
    public func save(_ identity: JobSigningIdentity, info: SigningIdentityInfo) throws {
        let p12 = try box.seal(identity.p12.base64EncodedString())
        let password = try box.seal(identity.password)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO signing_identity
                        (id, sealed_p12, sealed_password, name, team_id, serial_number, expires_at, created_at, origin, asc_certificate_id)
                    VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    p12, password, info.name, info.teamID, info.serialNumber, dbTime(info.expiresAt), dbTime(info.createdAt),
                    info.origin.rawValue, info.ascCertificateID,
                ])
        }
    }

    /// Deletes the stored copy; true when there was one. Revokes nothing.
    @discardableResult
    public func remove() throws -> Bool {
        try database.write { db in
            try db.execute(sql: "DELETE FROM signing_identity WHERE id = 1")
            return db.changesCount > 0
        }
    }

    // MARK: Creations (the 24-hour guard)

    /// Records that Hangar is about to ask App Store Connect for a certificate; returns the record's id.
    public func recordCreation(at date: Date) throws -> String {
        let id = UUID().uuidString
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO signing_certificate_creations (id, started_at) VALUES (?, ?)", arguments: [id, dbTime(date)])
        }
        return id
    }

    public func setCreationCertificate(_ id: String, ascCertificateID: String) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE signing_certificate_creations SET asc_certificate_id = ? WHERE id = ?", arguments: [ascCertificateID, id])
        }
    }

    /// Forgets a creation App Store Connect refused: no certificate came of it.
    public func forgetCreation(_ id: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM signing_certificate_creations WHERE id = ?", arguments: [id])
        }
    }

    public func lastCreation() throws -> Date? {
        try database.read { db in
            try Double.fetchOne(db, sql: "SELECT MAX(started_at) FROM signing_certificate_creations").map(dbDate)
        }
    }

    private static func info(_ row: Row) -> SigningIdentityInfo {
        SigningIdentityInfo(
            name: row["name"], teamID: row["team_id"], serialNumber: row["serial_number"],
            expiresAt: dbDate(row["expires_at"] as Double), createdAt: dbDate(row["created_at"] as Double),
            origin: SigningIdentityOrigin(rawValue: row["origin"]) ?? .imported, ascCertificateID: row["asc_certificate_id"])
    }
}
