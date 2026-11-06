import Foundation

/// A `hangar-worker` command as an administrator types it in Terminal on this Mac, for the messages the worker
/// prints and reports. It names the binary by its full path: `~/.local/bin` is on no one's PATH under sudo, and the
/// `hangar` user's is inside a home the administrator cannot read. It works whether the worker runs as the
/// dedicated `hangar` user (a LaunchDaemon) or as the Mac's owner (a launch agent).
public struct WorkerCommandLine: Sendable, Equatable {
    /// The worker's binary, e.g. /Users/hangar/.local/bin/hangar-worker.
    public var binary: String
    /// The user the worker runs as.
    public var user: String

    public init(binary: String, user: String) {
        self.binary = binary
        self.user = user
    }

    /// This process's binary and user.
    public static func current() -> WorkerCommandLine {
        let path = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "hangar-worker"
        return WorkerCommandLine(binary: URL(fileURLWithPath: path).resolvingSymlinksInPath().path, user: NSUserName())
    }

    /// As root: `sudo <binary> <arguments>`.
    public func asRoot(_ arguments: String...) -> String {
        (["sudo", binary] + arguments).map(GuestSSH.quote).joined(separator: " ")
    }

    /// As the worker's user, which owns the VM storage and the configuration: `sudo -u hangar -H <binary> …` for the
    /// dedicated user, whose home is closed to the administrator; the plain path for anyone else, who is the person
    /// at the Terminal.
    public func asWorker(_ arguments: String...) -> String {
        let prefix = user == WorkerPrivacy.dedicatedUser ? ["sudo", "-u", user, "-H"] : []
        return (prefix + [binary] + arguments).map(GuestSSH.quote).joined(separator: " ")
    }

    /// The one command that sets up, or repairs, VM builds on this Mac (`vm setup`).
    public var vmSetup: String { asRoot("vm", "setup") }
}
