import Foundation

/// The file modes that keep a worker's files away from other accounts on the Mac.
///
/// The data and work directories (holding each job's TMPDIR) are chmodded to 0700. The umask stays the usual 022: a
/// build's products must keep group and world read bits, or the installer package `xcodebuild -exportArchive` makes
/// holds files only their owner can read and App Store Connect rejects it ("files that are only readable by the root
/// user").
public enum WorkerPrivacy {
    /// Sets the process umask to 022, whatever launchd or the shell handed over; children (xcodebuild, hooks,
    /// post-actions) inherit it. Called by `run` only, so tests and the doctor keep their own umask.
    public static func standardUmask() {
        umask(0o022)
    }

    /// `chmod` that is not subject to umask and also applies to a directory that already existed.
    public static func setMode(_ mode: mode_t, at path: String) throws {
        guard chmod(path, mode) == 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path, "errno": errno])
        }
    }

    /// The warning `run` logs when builds run on this Mac itself (local builds); nil with VM builds on, where a build
    /// runs in a VM that cannot see the host.
    public static func startupWarning(
        user: String, vmBuilds: Bool = false, setupCommand: String = WorkerCommandLine.current().vmSetup
    ) -> String? {
        if vmBuilds { return nil }
        return "the worker is running as \(user), so a build can read \(user)'s files. Turn on VM builds, so each "
            + "build runs in a fresh macOS VM that cannot see them: \(setupCommand)"
    }
}
