import Foundation
import HangarCore
import Synchronization

/// Why a pairing code was refused.
public enum PairingError: Error, Equatable, Sendable {
    /// Unknown, expired or already used.
    case invalidCode
    /// Too many failed attempts recently; every attempt is refused until the window passes.
    case tooManyAttempts
}

/// The short-lived codes that let a new Mac enroll itself (`POST /enroll`) without copying a machine token.
///
/// A code is 8 characters from an alphabet without look-alikes (no 0/O, 1/I/L), shown as `XXXX-XXXX`, valid for
/// 15 minutes and good for one enrollment. At most 5 are live; creating a sixth drops the oldest. Redemption
/// ignores case, dashes and whitespace, and compares against every live code in constant time.
///
/// Failed redemptions are counted per peer (the remote address): after 10 within 10 minutes that peer is refused
/// until the oldest of them is 10 minutes old. As a backstop, 100 failures from all peers together within 10 minutes
/// refuse everyone the same way. Codes live in memory only: a server restart forgets them.
public final class PairingCodes: Sendable {
    public static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let length = 8
    static let lifetime: TimeInterval = 15 * 60
    static let maxLive = 5
    static let maxFailuresPerPeer = 10
    static let maxFailures = 100
    static let failureWindow: TimeInterval = 10 * 60

    private struct State {
        /// Normalized code (no dash) → its expiry, oldest first.
        var codes: [(code: String, expiresAt: Date)] = []
        /// Each recent failed redemption: when, and from which peer; oldest first.
        var failures: [(date: Date, peer: String)] = []
    }

    private let state = Mutex(State())
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    /// A new code, valid for 15 minutes.
    public func create() -> Pairing {
        var generator = SystemRandomNumberGenerator()
        let date = now()
        return state.withLock { state in
            Self.prune(&state, at: date)
            var code: String
            repeat {
                code = String((0..<Self.length).map { _ in Self.alphabet.randomElement(using: &generator)! })
            } while state.codes.contains { $0.code == code }
            let expiresAt = date.addingTimeInterval(Self.lifetime)
            state.codes.append((code, expiresAt))
            if state.codes.count > Self.maxLive { state.codes.removeFirst(state.codes.count - Self.maxLive) }
            return Pairing(code: Self.display(code), expiresAt: expiresAt, expiresIn: Int(Self.lifetime))
        }
    }

    /// Spends `code` on `body`, run while the code is held so no other redemption can use it. When `body` throws,
    /// the code stays valid and the error is rethrown; that is not counted as a failed attempt. `peer` identifies
    /// the caller for the rate limit (the remote address).
    /// Throws `PairingError.tooManyAttempts` while rate-limited, `.invalidCode` for an unknown, used or expired code.
    public func redeem<T>(_ code: String, from peer: String = "", _ body: () throws -> T) throws -> T {
        let date = now()
        let key = Array(Self.normalize(code).utf8)
        return try state.withLock { state in
            Self.prune(&state, at: date)
            guard state.failures.count < Self.maxFailures,
                state.failures.count(where: { $0.peer == peer }) < Self.maxFailuresPerPeer
            else { throw PairingError.tooManyAttempts }
            // Every live code is compared, each in constant time, so the timing says nothing about which matched.
            var match: Int?
            for (index, entry) in state.codes.enumerated() where Self.constantTimeEqual(key, Array(entry.code.utf8)) {
                match = index
            }
            guard let index = match else {
                state.failures.append((date, peer))
                throw PairingError.invalidCode
            }
            let result = try body()
            state.codes.remove(at: index)
            return result
        }
    }

    /// Equal bytes, compared without returning early; a length difference only makes the result false.
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= x ^ y
        }
        return difference == 0 && a.count == b.count
    }

    /// Spends `code`; false when it is not valid (or redemption is rate-limited).
    public func redeem(_ code: String) -> Bool { (try? redeem(code) {}) != nil }

    /// Live codes, for tests.
    var liveCount: Int {
        let date = now()
        return state.withLock { state in
            Self.prune(&state, at: date)
            return state.codes.count
        }
    }

    /// Failed redemptions within the window, for tests.
    var recentFailures: Int {
        let date = now()
        return state.withLock { state in
            Self.prune(&state, at: date)
            return state.failures.count
        }
    }

    private static func prune(_ state: inout State, at date: Date) {
        state.codes.removeAll { $0.expiresAt <= date }
        state.failures.removeAll { date.timeIntervalSince($0.date) >= failureWindow }
    }

    /// Upper-cased, without dashes or whitespace.
    static func normalize(_ code: String) -> String {
        String(code.uppercased().filter { $0 != "-" && !$0.isWhitespace })
    }

    static func display(_ code: String) -> String { "\(code.prefix(4))-\(code.dropFirst(4))" }
}
