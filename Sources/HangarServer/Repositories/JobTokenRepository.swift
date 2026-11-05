import CryptoKit
import Foundation
import GRDB
import HangarCore

/// One-job tokens (VM builds design, *How the worker talks to the guest*): the host worker asks for one per job and
/// hands it to the job's VM instead of its machine token. The token is returned once by `issue`; only its SHA-256
/// hex is stored.
public struct JobTokenRepository: Sendable {
    let database: Database

    /// Every job token starts with this, so a request can tell one from a machine token (which has no prefix).
    public static let prefix = "hgj_"

    public init(database: Database) { self.database = database }

    /// A new token for `jobID`, valid for as long as the job is assigned to `machineID` and not finished. Also drops
    /// the tokens of jobs that have finished since, which no longer authenticate anyway.
    public func issue(jobID: UUID, machineID: UUID, now: Date = Date()) throws -> String {
        let token = Self.prefix + Self.base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        try database.write { db in
            try db.execute(
                sql: """
                    DELETE FROM job_tokens WHERE job_id IN (SELECT id FROM jobs WHERE status IN ('succeeded', 'failed', 'cancelled'))
                    """)
            try db.execute(
                sql: "INSERT INTO job_tokens (token_hash, job_id, machine_id, created_at) VALUES (?, ?, ?, ?)",
                arguments: [Self.hash(token), jobID.uuidString, machineID.uuidString, dbTime(now)])
        }
        return token
    }

    /// The job and machine of a token, nil when it is unknown or revoked, or its job has finished or is no longer
    /// assigned to the machine it was issued to (cancelled, failed as lost, requeued, reassigned).
    public func authenticate(token: String) throws -> (jobID: UUID, machineID: UUID)? {
        guard token.hasPrefix(Self.prefix) else { return nil }
        return try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT job_tokens.job_id, job_tokens.machine_id FROM job_tokens
                        JOIN jobs ON jobs.id = job_tokens.job_id
                        WHERE job_tokens.token_hash = ? AND jobs.status IN ('assigned', 'running')
                            AND jobs.machine_id = job_tokens.machine_id
                        """,
                    arguments: [Self.hash(token)]),
                let jobID = UUID(uuidString: row["job_id"]), let machineID = UUID(uuidString: row["machine_id"])
            else { return nil }
            return (jobID, machineID)
        }
    }

    /// Deletes the job's tokens: all of them, or only those issued to `machineID`.
    public func revoke(jobID: UUID, machineID: UUID? = nil) throws {
        try database.write { db in
            if let machineID {
                try db.execute(
                    sql: "DELETE FROM job_tokens WHERE job_id = ? AND machine_id = ?",
                    arguments: [jobID.uuidString, machineID.uuidString])
            } else {
                try db.execute(sql: "DELETE FROM job_tokens WHERE job_id = ?", arguments: [jobID.uuidString])
            }
        }
    }

    /// How many tokens of the job are stored, valid or not; for tests.
    func count(jobID: UUID) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job_tokens WHERE job_id = ?", arguments: [jobID.uuidString]) ?? 0
        }
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
