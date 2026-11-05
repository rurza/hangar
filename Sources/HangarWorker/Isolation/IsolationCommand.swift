import Darwin
import Foundation
import HangarCore

/// One command `hangar-worker isolate` runs. Every account, file and launchd change goes through this type, so a test
/// can assert the whole sequence and `--dry-run` can print it without running it.
public struct IsolationCommand: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// Reads state without changing anything and without sudo. `--dry-run` runs these for real.
        case probe
        /// Changes something, or needs sudo. `--dry-run` only prints these.
        case change
    }

    /// The complete argv; `arguments[0]` is an absolute path (`/usr/bin/sudo` for a privileged command).
    public var arguments: [String]
    public var kind: Kind
    /// Written to the command's standard input, then closed. Never part of the description.
    public var input: SensitiveText?
    /// Collects standard output instead of passing it to the terminal.
    public var capturesOutput: Bool
    /// Sends standard error to /dev/null (for probes whose failure is an answer, like `id -u hangar`).
    public var quiet: Bool
    /// Arguments shown as `<redacted>` in the description, such as the throwaway password `sysadminctl` gets.
    public var redactedArguments: Set<String>

    public init(
        _ arguments: [String], kind: Kind, input: SensitiveText? = nil, capturesOutput: Bool = false,
        quiet: Bool = false, redactedArguments: Set<String> = []
    ) {
        self.arguments = arguments
        self.kind = kind
        self.input = input
        self.capturesOutput = capturesOutput
        self.quiet = quiet
        self.redactedArguments = redactedArguments
    }

    /// A read-only command run as the invoking user.
    public static func probe(_ arguments: String...) -> IsolationCommand {
        IsolationCommand(arguments, kind: .probe, capturesOutput: true, quiet: true)
    }

    /// A command run with `sudo` (which asks for the administrator's password when its timestamp has expired).
    public static func sudo(_ arguments: String...) -> IsolationCommand {
        IsolationCommand(["/usr/bin/sudo"] + arguments, kind: .change)
    }

    /// A command run as the invoking user that changes something.
    public static func change(_ arguments: String...) -> IsolationCommand {
        IsolationCommand(arguments, kind: .change)
    }

    public var isPrivileged: Bool { arguments.first == "/usr/bin/sudo" }

    /// The command as a shell line, with redacted arguments and stdin shown as placeholders.
    public var description: String {
        let words = arguments.map { redactedArguments.contains($0) ? "<redacted>" : Self.quote($0) }
        return words.joined(separator: " ") + (input == nil ? "" : " <<< <redacted>")
    }

    static func quote(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

public struct IsolationResult: Sendable, Equatable {
    public var exitCode: Int32
    /// Standard output when the command captures it, otherwise empty.
    public var output: String

    public init(exitCode: Int32, output: String = "") {
        self.exitCode = exitCode
        self.output = output
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// Runs isolation commands. The live runner attaches them to the terminal so `sudo` can ask for a password.
public protocol IsolationRunner: Sendable {
    func run(_ command: IsolationCommand) throws -> IsolationResult
}

/// Runs a real command with `posix_spawn`, in this process's process group, so `sudo` reads the password from the
/// terminal like any command typed at the prompt (Foundation's `Process` moves the child into its own process group,
/// where reading the terminal stops it). Standard error stays on the terminal unless the command is quiet.
public struct TerminalRunner: IsolationRunner {
    public init() {}

    public func run(_ command: IsolationCommand) throws -> IsolationResult {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        var inputPipe: [Int32] = [-1, -1]
        var outputPipe: [Int32] = [-1, -1]
        if command.input != nil {
            guard pipe(&inputPipe) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            posix_spawn_file_actions_adddup2(&actions, inputPipe[0], 0)
            posix_spawn_file_actions_addclose(&actions, inputPipe[1])
        }
        if command.capturesOutput {
            guard pipe(&outputPipe) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 1)
            posix_spawn_file_actions_addclose(&actions, outputPipe[0])
        }
        if command.quiet {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }

        let argv: [UnsafeMutablePointer<CChar>?] = command.arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, command.arguments[0], &actions, nil, argv, environ)
        if inputPipe[0] >= 0 { close(inputPipe[0]) }
        if outputPipe[1] >= 0 { close(outputPipe[1]) }
        guard status == 0 else {
            if inputPipe[1] >= 0 { close(inputPipe[1]) }
            if outputPipe[0] >= 0 { close(outputPipe[0]) }
            throw POSIXError(.init(rawValue: status) ?? .EIO)
        }

        if let input = command.input {
            let bytes = Array(input.value.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBufferPointer { write(inputPipe[1], $0.baseAddress, $0.count) }
                if written < 0 { if errno == EINTR { continue } else { break } }
                offset += written
            }
            close(inputPipe[1])
        }
        var output = Data()
        if command.capturesOutput {
            let handle = FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: true)
            output = handle.readDataToEndOfFile()
        }
        var exit: Int32 = 0
        while waitpid(pid, &exit, 0) < 0 && errno == EINTR {}
        let code: Int32 = (exit & 0x7f) == 0 ? (exit >> 8) & 0xff : 128 + (exit & 0x7f)
        var text = String(decoding: output, as: UTF8.self)
        while text.hasSuffix("\n") { text.removeLast() }
        return IsolationResult(exitCode: code, output: text)
    }
}

/// `--dry-run`: runs probes for real and prints every change instead of running it; a change "succeeds" with no
/// output. Nothing with `sudo` runs.
public struct DryRunRunner: IsolationRunner {
    private let live: any IsolationRunner
    private let print: @Sendable (String) -> Void

    public init(live: any IsolationRunner = TerminalRunner(), print: @escaping @Sendable (String) -> Void) {
        self.live = live
        self.print = print
    }

    public func run(_ command: IsolationCommand) throws -> IsolationResult {
        if command.kind == .probe && !command.isPrivileged { return try live.run(command) }
        print("  would run: \(command)")
        return IsolationResult(exitCode: 0)
    }
}
