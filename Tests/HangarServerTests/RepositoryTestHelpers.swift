import Foundation
import GRDB
import HangarCore

@testable import HangarServer

/// Shortcuts the server never takes: tests set up state directly instead of through the guarded transitions.
extension BuildRepository {
    /// Moves the job to `status` whatever it is now.
    func setJobStatus(id: UUID, status: JobStatus, at date: Date, failureReason: String? = nil) throws {
        let any: Set<JobStatus> = [.queued, .assigned, .running, .succeeded, .failed, .cancelled]
        try transitionJob(id: id, from: any, to: status, at: date, failureReason: failureReason)
    }

    /// Fails with a constraint error when the number is already reserved for the app.
    func reserveNumber(appID: UUID, number: Int, buildID: UUID) throws {
        try inTransaction { db in try Self.reserveNumber(db, appID: appID, number: number, buildID: buildID) }
    }
}

extension PairingCodes {
    /// Spends `code`; false when it is not valid (or redemption is rate-limited).
    func redeem(_ code: String) -> Bool { (try? redeem(code) {}) != nil }
}
