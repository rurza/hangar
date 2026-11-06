import Foundation
import IOKit

/// Whether a login session on this Mac has its screen locked.
///
/// Virtualization.framework encrypts a saved state with a Secure Enclave key of the user who saved it. Saving needs
/// only the public half, so it works with the screen locked; restoring needs the private half, which the Secure
/// Enclave refuses while that user's session is locked (`errSecInteractionNotAllowed`, -25308, which the framework
/// reports as a restore that "failed with error permission denied"). Seen on the MacBook on 2026-11-06: every restore
/// between the screen locking at 01:22 and unlocking at 08:31 failed that way, the same state restored right after.
public enum ConsoleLock {
    /// Reads `IOConsoleUsers` from the I/O Registry root, which any process may read (a LaunchDaemon with no session
    /// too): loginwindow sets `CGSSessionScreenIsLocked` on a session while its screen is locked.
    @Sendable public static func screenIsLocked() -> Bool {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        guard
            let property = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        else { return false }
        return anySessionIsLocked(property as? [[String: Any]] ?? [])
    }

    static func anySessionIsLocked(_ sessions: [[String: Any]]) -> Bool {
        sessions.contains { ($0["CGSSessionScreenIsLocked"] as? Bool) == true }
    }
}
