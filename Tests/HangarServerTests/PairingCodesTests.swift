import Foundation
import Synchronization
import Testing

@testable import HangarServer

/// A wall clock the test moves by hand.
final class ManualClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { current.withLock { $0 } }
    func advance(by seconds: TimeInterval) { current.withLock { $0 += seconds } }
}

@Suite struct PairingCodesTests {
    @Test func codesAreEightUnambiguousCharactersShownWithADash() {
        let clock = ManualClock()
        let codes = PairingCodes(now: { clock.now })
        for _ in 0..<50 {
            let pairing = codes.create()
            #expect(pairing.code.wholeMatch(of: /[A-Z2-9]{4}-[A-Z2-9]{4}/) != nil)
            let letters = pairing.code.replacingOccurrences(of: "-", with: "")
            #expect(letters.allSatisfy { PairingCodes.alphabet.contains($0) })
            #expect(!letters.contains { "01ILO".contains($0) })
            #expect(pairing.expiresAt == clock.now.addingTimeInterval(15 * 60))
            #expect(pairing.expiresIn == 15 * 60)
        }
    }

    @Test func aCodeWorksOnce() {
        let clock = ManualClock()
        let codes = PairingCodes(now: { clock.now })
        let pairing = codes.create()
        #expect(codes.redeem(pairing.code))
        #expect(!codes.redeem(pairing.code))
    }

    @Test func aCodeExpiresAfterFifteenMinutes() {
        let clock = ManualClock()
        let codes = PairingCodes(now: { clock.now })
        let early = codes.create()
        let late = codes.create()
        clock.advance(by: 15 * 60 - 1)
        #expect(codes.redeem(early.code))
        clock.advance(by: 1)
        #expect(!codes.redeem(late.code))
    }

    @Test func redeemIgnoresCaseDashesAndSpaces() {
        let clock = ManualClock()
        let codes = PairingCodes(now: { clock.now })
        let first = codes.create()
        #expect(codes.redeem(first.code.lowercased()))
        let second = codes.create()
        #expect(codes.redeem(" " + second.code.replacingOccurrences(of: "-", with: "") + "\n"))
    }

    @Test func atMostFiveCodesLiveAndTheOldestIsDropped() {
        let clock = ManualClock()
        let codes = PairingCodes(now: { clock.now })
        let pairings = (0..<6).map { _ in codes.create() }
        #expect(codes.liveCount == 5)
        #expect(!codes.redeem(pairings[0].code))
        for pairing in pairings.dropFirst() { #expect(codes.redeem(pairing.code)) }
    }

    @Test func aFailingBodyKeepsTheCode() throws {
        let clock = ManualClock()
        let codes = PairingCodes(now: { clock.now })
        let pairing = codes.create()
        struct Taken: Error {}
        #expect(throws: Taken.self) { try codes.redeem(pairing.code) { throw Taken() } }
        #expect(codes.redeem(pairing.code))
    }

    @Test func tenFailuresInTenMinutesBlockRedemptionForTheRestOfTheWindow() throws {
        let clock = ManualClock()
        let codes = PairingCodes(now: { clock.now })
        let pairing = codes.create()
        for _ in 0..<10 {
            #expect(throws: PairingError.invalidCode) { try codes.redeem("AAAA-AAAA") {} }
            clock.advance(by: 30)
        }
        // Even the right code is refused while the window lasts.
        #expect(throws: PairingError.tooManyAttempts) { try codes.redeem(pairing.code) {} }
        // The first failure leaves the window 10 minutes after it was made: 9 failures remain, under the limit.
        clock.advance(by: 10 * 60 - 10 * 30)
        #expect(throws: Never.self) { try codes.redeem(pairing.code) {} }
    }

    @Test func expiredCodesCountAsFailures() {
        let clock = ManualClock()
        let codes = PairingCodes(now: { clock.now })
        let pairing = codes.create()
        clock.advance(by: 16 * 60)
        #expect(throws: PairingError.invalidCode) { try codes.redeem(pairing.code) {} }
        #expect(codes.recentFailures == 1)
    }

    @Test func failuresAreCountedPerPeer() throws {
        let clock = ManualClock()
        let codes = PairingCodes(now: { clock.now })
        let pairing = codes.create()
        for _ in 0..<10 {
            #expect(throws: PairingError.invalidCode) { try codes.redeem("AAAA-AAAA", from: "100.64.0.9") {} }
        }
        #expect(throws: PairingError.tooManyAttempts) { try codes.redeem(pairing.code, from: "100.64.0.9") {} }
        // Another Mac on the tailnet is not locked out by the first one's mistakes.
        #expect(throws: Never.self) { try codes.redeem(pairing.code, from: "100.64.0.10") {} }
    }

    @Test func aHundredFailuresFromAnyPeersLockEveryone() throws {
        let clock = ManualClock()
        let codes = PairingCodes(now: { clock.now })
        let pairing = codes.create()
        for attempt in 0..<100 {
            #expect(throws: PairingError.invalidCode) {
                try codes.redeem("AAAA-AAAA", from: "peer-\(attempt / 5)") {}
            }
        }
        #expect(throws: PairingError.tooManyAttempts) { try codes.redeem(pairing.code, from: "someone-new") {} }
    }

    @Test func codesOfOtherLengthsNeverMatch() {
        let clock = ManualClock()
        let codes = PairingCodes(now: { clock.now })
        let pairing = codes.create()
        let letters = pairing.code.replacingOccurrences(of: "-", with: "")
        #expect(!codes.redeem(String(letters.prefix(7))))
        #expect(!codes.redeem(letters + "A"))
        #expect(codes.redeem(letters))
    }
}
