import Foundation
import GRDB
import HangarCore

/// The App Store Connect keys the server holds, sealed with the master key like secret variables. They are settings,
/// not variables: no job's environment ever has them.
///
/// - `main`: the team key Settings › App Store Connect stores. The server's own calls (certificates, profiles,
///   TestFlight groups, build numbers, icons) use it, and a worker gets it in an assignment only for the `xcodebuild`
///   steps and App Store Connect calls it runs itself. It never enters a VM guest.
/// - `development`: optional, a team key with the Developer role. Only a VM archive whose development profiles the
///   server could not provide gets it, for the guest's `-allowProvisioningUpdates`.
public struct AppStoreConnectKeyRepository: Sendable {
    public enum Role: String, Sendable, CaseIterable {
        case main
        case development
    }

    let database: Database
    let box: SecretBox

    public init(database: Database, box: SecretBox) {
        self.database = database
        self.box = box
    }

    /// Nil when there is none.
    public func key(_ role: Role) throws -> AppStoreConnectKey? {
        guard let row = try database.read({ db in
            try Row.fetchOne(
                db, sql: "SELECT sealed_key_id, sealed_issuer_id, sealed_private_key FROM app_store_connect_keys WHERE role = ?",
                arguments: [role.rawValue])
        }) else { return nil }
        let keyID = try box.open(row["sealed_key_id"] as Data)
        let privateKey = try box.open(row["sealed_private_key"] as Data)
        guard !keyID.isEmpty, !privateKey.isEmpty else { return nil }
        let issuerID = try (row["sealed_issuer_id"] as Data?).map(box.open).flatMap { $0.isEmpty ? nil : $0 }
        return AppStoreConnectKey(keyID: keyID, issuerID: issuerID, privateKey: privateKey)
    }

    /// The key ID and kind, without opening the private key.
    public func status(_ role: Role) throws -> ASCKeyStatus? {
        try key(role).map { ASCKeyStatus(keyID: $0.keyID, issuerID: $0.issuerID) }
    }

    public func set(_ role: Role, _ key: AppStoreConnectKey, now: Date = Date()) throws {
        let keyID = try box.seal(key.keyID)
        let issuerID = try key.issuerID.flatMap { $0.isEmpty ? nil : $0 }.map(box.seal)
        let privateKey = try box.seal(key.privateKey)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO app_store_connect_keys
                        (role, sealed_key_id, sealed_issuer_id, sealed_private_key, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [role.rawValue, keyID, issuerID, privateKey, dbTime(now)])
        }
    }

    @discardableResult
    public func remove(_ role: Role) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "DELETE FROM app_store_connect_keys WHERE role = ?", arguments: [role.rawValue])
            return db.changesCount > 0
        }
    }
}
