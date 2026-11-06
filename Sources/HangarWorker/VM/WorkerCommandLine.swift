import Foundation

/// A `hangar-worker` command as an administrator types it in Terminal on this Mac, for the messages the worker
/// prints and reports. It names the binary by its full path: `~/.local/bin` is on no one's PATH under sudo. The
/// worker runs as the Mac's owner (a launch agent), who is the person at the Terminal.
public struct WorkerCommandLine: Sendable, Equatable {
    /// The worker's binary, e.g. /Users/adam/.local/bin/hangar-worker.
    public var binary: String

    public init(binary: String) {
        self.binary = binary
    }

    /// This process's binary.
    public static func current() -> WorkerCommandLine {
        let path = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "hangar-worker"
        return WorkerCommandLine(binary: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    /// As root: `sudo <binary> <arguments>`.
    public func asRoot(_ arguments: String...) -> String {
        (["sudo", binary] + arguments).map(GuestSSH.quote).joined(separator: " ")
    }

    /// As the worker's user, which owns the VM storage and the configuration: the plain path.
    public func asWorker(_ arguments: String...) -> String {
        ([binary] + arguments).map(GuestSSH.quote).joined(separator: " ")
    }

    /// The one command that sets up, or repairs, VM builds on this Mac (`vm setup`).
    public var vmSetup: String { asRoot("vm", "setup") }
}
