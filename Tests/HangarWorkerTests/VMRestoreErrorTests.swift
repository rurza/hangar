import Foundation
import Testing

@testable import HangarWorker

#if arch(arm64)
import Virtualization

@Suite struct VMRestoreErrorTests {
    static func restoreError(_ description: String, underlying: NSError? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
        if let underlying { userInfo[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: VZErrorDomain, code: VZError.Code.restore.rawValue, userInfo: userInfo)
    }

    /// The words macOS 27.2 logged for every restore while the MacBook's screen was locked.
    @Test func aRestoreRefusedWithPermissionDeniedIsUnreadableNotIncompatible() {
        let error = Self.restoreError(
            "An error occurred while restoring the virtual machine. The virtual machine failed to restore with error “permission denied”.")
        guard case .stateUnreadable = LiveVirtualMachineEngine.map(error, restoring: true) else {
            Issue.record("expected stateUnreadable, got \(LiveVirtualMachineEngine.map(error, restoring: true))")
            return
        }
    }

    @Test func anUnderlyingPOSIXPermissionErrorCountsToo() {
        let error = Self.restoreError(
            "The virtual machine failed to restore.", underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)))
        guard case .stateUnreadable = LiveVirtualMachineEngine.map(error, restoring: true) else {
            Issue.record("expected stateUnreadable")
            return
        }
    }

    @Test func anyOtherRestoreFailureIsStillIncompatible() {
        let error = Self.restoreError("The virtual machine failed to restore with error “invalid argument”.")
        guard case .stateIncompatible = LiveVirtualMachineEngine.map(error, restoring: true) else {
            Issue.record("expected stateIncompatible")
            return
        }
        guard case .failed = LiveVirtualMachineEngine.map(Self.restoreError("permission denied"), restoring: false) else {
            Issue.record("a start or save error is not a restore's")
            return
        }
    }
}
#endif

@Suite struct ConsoleLockTests {
    @Test func aSessionIsLockedOnlyWhenLoginwindowSaysSo() {
        #expect(!ConsoleLock.anySessionIsLocked([]))
        #expect(!ConsoleLock.anySessionIsLocked([["kCGSSessionUserNameKey": "adam", "kCGSSessionOnConsoleKey": true]]))
        #expect(!ConsoleLock.anySessionIsLocked([["CGSSessionScreenIsLocked": false]]))
        #expect(ConsoleLock.anySessionIsLocked([
            ["kCGSSessionUserNameKey": "other"], ["kCGSSessionUserNameKey": "adam", "CGSSessionScreenIsLocked": true],
        ]))
    }

    /// This Mac's registry reads without failing, whatever its screen is doing.
    @Test func theLiveProbeAnswers() {
        _ = ConsoleLock.screenIsLocked()
    }
}
