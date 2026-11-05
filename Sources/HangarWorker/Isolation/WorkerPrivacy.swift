import Foundation

/// The file modes that keep a worker's files away from other accounts on the Mac (docs: worker isolation design).
///
/// The boundary is the dedicated `hangar` user's home at mode 0700. The worker keeps it that way after install without
/// walking the cache: the data and work directories (holding each job's TMPDIR) are chmodded to 0700, and the home
/// itself is chmodded only when the process really is that user. The umask stays the usual 022: a build's products
/// must keep group and world read bits, or the installer package `xcodebuild -exportArchive` makes holds files only
/// their owner can read and App Store Connect rejects it ("files that are only readable by the root user").
public enum WorkerPrivacy {
    /// The dedicated build account's short name.
    public static let dedicatedUser = "hangar"
    /// Its home.
    public static let dedicatedHome = "/Users/hangar"

    /// Sets the process umask to 022, whatever launchd or the shell handed over; children (xcodebuild, hooks,
    /// post-actions) inherit it. Called by `run` only, so tests and the doctor keep their own umask.
    public static func standardUmask() {
        umask(0o022)
    }

    /// Whether `user` with home `home` is the dedicated account whose home the worker may lock down.
    public static func isDedicatedAccount(user: String, home: String) -> Bool {
        user == dedicatedUser && URL(fileURLWithPath: home).standardizedFileURL.path == dedicatedHome
    }

    /// Strips the ACL from `home` and sets it to mode 0700. Takes the path so tests can pass a temporary directory;
    /// callers check `isDedicatedAccount` first.
    public static func lockDown(home: String) throws {
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/bin/chmod")
        strip.arguments = ["-N", home]
        strip.standardError = FileHandle.nullDevice
        try strip.run()
        strip.waitUntilExit()  // -N fails harmlessly when there is no ACL to remove.
        try setMode(0o700, at: home)
    }

    /// `chmod` that is not subject to umask and also applies to a directory that already existed.
    public static func setMode(_ mode: mode_t, at path: String) throws {
        guard chmod(path, mode) == 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path, "errno": errno])
        }
    }

    /// The warning `run` logs when the worker is not the dedicated account; nil when it is.
    public static func startupWarning(user: String, home: String) -> String? {
        if isDedicatedAccount(user: user, home: home) { return nil }
        return "the worker is running as \(user), so a build can read \(user)'s files. Run `hangar-worker isolate` "
            + "as an administrator to move it to the dedicated \(dedicatedUser) user."
    }
}
