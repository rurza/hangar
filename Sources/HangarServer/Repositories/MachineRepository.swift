import CryptoKit
import Foundation
import GRDB
import HangarCore

public struct MachineRepository: Sendable {
    let database: Database

    public init(database: Database) { self.database = database }

    public func inTransaction<T>(_ body: (GRDB.Database) throws -> T) throws -> T { try database.write(body) }

    /// The token is returned once; only its SHA-256 hex is stored.
    public func create(name: String, maxConcurrentJobs: Int = 1) throws -> (Machine, token: String) {
        let token = Self.base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        let machine = Machine(
            id: UUID(), name: name, maxConcurrentJobs: maxConcurrentJobs,
            createdAt: Date(timeIntervalSince1970: dbTime(Date())))
        let exists = APIError(code: "machine_exists", message: "A machine named '\(name)' already exists.")
        do {
            try database.write { db in
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM machines WHERE name = ?)", arguments: [name]) == true {
                    throw exists
                }
                try db.execute(
                    sql: """
                        INSERT INTO machines (id, name, token_hash, max_concurrent_jobs, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [machine.id.uuidString, name, Self.hash(token), maxConcurrentJobs, dbTime(machine.createdAt)])
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            // The check above runs in the same write transaction, so only a second writer outside this process
            // could get here; it still means the name is taken.
            throw exists
        }
        return (machine, token)
    }

    public func authenticate(token: String) throws -> Machine? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM machines WHERE token_hash = ?", arguments: [Self.hash(token)])
                .map(Self.machine)
        }
    }

    public func all() throws -> [Machine] {
        try database.read { db in try Row.fetchAll(db, sql: "SELECT * FROM machines ORDER BY name").map(Self.machine) }
    }

    public func find(nameOrID: String) throws -> Machine? {
        try database.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM machines WHERE name = ? OR id = ?",
                arguments: [nameOrID, nameOrID.uppercased()]
            ).map(Self.machine)
        }
    }

    public func updateReport(id: UUID, report: MachineReport, seenAt: Date) throws {
        let json = String(decoding: try JSONCoding.encoder.encode(report), as: UTF8.self)
        try database.write { db in
            try db.execute(
                sql: "UPDATE machines SET report_json = ?, last_seen_at = ? WHERE id = ?",
                arguments: [json, dbTime(seenAt), id.uuidString])
        }
    }

    public func delete(id: UUID) throws {
        try database.write { db in try db.execute(sql: "DELETE FROM machines WHERE id = ?", arguments: [id.uuidString]) }
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func machine(_ row: Row) throws -> Machine {
        let report: String? = row["report_json"]
        return Machine(
            id: UUID(uuidString: row["id"])!, name: row["name"], maxConcurrentJobs: row["max_concurrent_jobs"],
            lastSeenAt: dbDate(row["last_seen_at"] as Double?),
            report: try report.map { try JSONCoding.decoder.decode(MachineReport.self, from: Data($0.utf8)) },
            createdAt: dbDate(row["created_at"] as Double))
    }
}
