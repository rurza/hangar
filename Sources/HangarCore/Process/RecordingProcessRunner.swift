import Foundation
import Synchronization

/// Test double for `ProcessRunner`: records every command and answers from scripts.
/// Unscripted commands exit 0 with no output. When several scripts match, the first registered wins.
public final class RecordingProcessRunner: ProcessRunner {
    private enum Reply {
        case outcome(lines: [String], exitCode: Int32)
        case hang
    }

    private struct Script {
        var match: @Sendable (ProcessCommand) -> Bool
        var reply: Reply
    }

    private struct State {
        var commands: [ProcessCommand] = []
        var scripts: [Script] = []
    }

    private let state = Mutex(State())

    public init() {}

    public var commands: [ProcessCommand] { state.withLock { $0.commands } }

    public func script(_ match: @escaping @Sendable (ProcessCommand) -> Bool, lines: [String], exitCode: Int32 = 0) {
        state.withLock { $0.scripts.append(Script(match: match, reply: .outcome(lines: lines, exitCode: exitCode))) }
    }

    /// Matching commands never finish until their task is cancelled, then throw `CancellationError`.
    public func scriptHang(_ match: @escaping @Sendable (ProcessCommand) -> Bool) {
        state.withLock { $0.scripts.append(Script(match: match, reply: .hang)) }
    }

    public func run(_ command: ProcessCommand, onLine: @Sendable (String) -> Void) async throws -> ProcessOutcome {
        let reply = state.withLock { state -> Reply? in
            state.commands.append(command)
            return state.scripts.first { $0.match(command) }?.reply
        }
        switch reply {
        case .none:
            return ProcessOutcome(exitCode: 0, output: "")
        case .outcome(let lines, let exitCode):
            lines.forEach(onLine)
            return ProcessOutcome(exitCode: exitCode, output: lines.joined(separator: "\n"))
        case .hang:
            while true { try await Task.sleep(for: .seconds(3600)) }
        }
    }
}
