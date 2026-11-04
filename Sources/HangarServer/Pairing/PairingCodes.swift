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
/// ignores case, dashes and whitespace. After 10 failed redemptions within 10 minutes every redemption is refused
/// until the oldest of them is 10 minutes old. Codes live in memory only: a server restart forgets them.
public final class PairingCodes: Sendable {
    public static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let length = 8
    static let lifetime: TimeInterval = 15 * 60
    static let maxLive = 5
    static let maxFailures = 10
    static let failureWindow: TimeInterval = 10 * 60

    private struct State {
        /// Normalized code (no dash) → its expiry, oldest first.
        var codes: [(code: String, expiresAt: Date)] = []
        /// When each recent failed redemption happened, oldest first.
        var failures: [Date] = []
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
            return Pairing(code: Self.display(code), expiresAt: expiresAt)
        }
    }

    /// Spends `code` on `body`, run while the code is held so no other redemption can use it. When `body` throws,
    /// the code stays valid and the error is rethrown; that is not counted as a failed attempt.
    /// Throws `PairingError.tooManyAttempts` while rate-limited, `.invalidCode` for an unknown, used or expired code.
    public func redeem<T>(_ code: String, _ body: () throws -> T) throws -> T {
        let date = now()
        let key = Self.normalize(code)
        return try state.withLock { state in
            Self.prune(&state, at: date)
            guard state.failures.count < Self.maxFailures else { throw PairingError.tooManyAttempts }
            guard let index = state.codes.firstIndex(where: { $0.code == key }) else {
                state.failures.append(date)
                throw PairingError.invalidCode
            }
            let result = try body()
            state.codes.remove(at: index)
            return result
        }
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
        state.failures.removeAll { date.timeIntervalSince($0) >= failureWindow }
    }

    /// Upper-cased, without dashes or whitespace.
    static func normalize(_ code: String) -> String {
        String(code.uppercased().filter { $0 != "-" && !$0.isWhitespace })
    }

    static func display(_ code: String) -> String { "\(code.prefix(4))-\(code.dropFirst(4))" }
}
