import Foundation
import Synchronization

public struct ProcessCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// The complete environment of the child; nothing is inherited.
    public var environment: [String: String]
    public var currentDirectory: String?
    /// Sends stderr to /dev/null, for tools whose stdout is parsed (JSON from `simctl` or `xcresulttool`).
    public var discardsStandardError: Bool

    public init(
        executable: String, arguments: [String], environment: [String: String] = [:], currentDirectory: String? = nil,
        discardsStandardError: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.discardsStandardError = discardsStandardError
    }
}

public struct ProcessOutcome: Sendable, Equatable {
    public var exitCode: Int32
    /// Every output line, joined with `\n`.
    public var output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

/// Every external tool (git, xcodebuild, hooks, codesign) runs through this seam.
/// stdout and stderr are merged and delivered line by line, in order of arrival (stderr is dropped instead when the
/// command `discardsStandardError`).
public protocol ProcessRunner: Sendable {
    func run(_ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessOutcome
}

/// Runs a real child process with Foundation `Process`.
///
/// An executable that is not an absolute path is resolved through `/usr/bin/env` using the child's own `PATH`.
/// On task cancellation the child gets SIGTERM, then SIGKILL after a grace period, and `CancellationError` is thrown.
public struct LiveProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessOutcome {
        try Task.checkCancellation()
        let session = Session()
        let outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.start(command, onLine: onLine, continuation: continuation)
            }
        } onCancel: {
            session.cancel()
        }
        if session.wasCancelled { throw CancellationError() }
        return outcome
    }
}

extension LiveProcessRunner {
    /// One child process. State lives behind a `Mutex`, so handlers may fire on any queue.
    fileprivate final class Session: Sendable {
        private struct State {
            var process: Process?
            var readHandle: FileHandle?
            var onLine: (@Sendable (String) -> Void)?
            var continuation: CheckedContinuation<ProcessOutcome, any Error>?
            var buffer = Data()
            var lines: [String] = []
            var exitCode: Int32?
            var reachedEOF = false
            var cancelled = false
            /// Bumped on every chunk after exit, so only the latest idle timer can fire.
            var idleGeneration = 0
            /// True while `onLine` is being called outside the lock; the idle cap must not fire then.
            var delivering = false
            /// Set once the idle cap gave up on the pipe; later chunks are ignored.
            var abandoned = false
        }

        private let state = Mutex(State())

        var wasCancelled: Bool { state.withLock { $0.cancelled } }

        func start(
            _ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void,
            continuation: CheckedContinuation<ProcessOutcome, any Error>
        ) {
            let process = Process()
            if command.executable.hasPrefix("/") {
                process.executableURL = URL(fileURLWithPath: command.executable)
                process.arguments = command.arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command.executable] + command.arguments
            }
            process.environment = command.environment
            if let directory = command.currentDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
            }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = command.discardsStandardError ? FileHandle.nullDevice : pipe
            process.standardInput = FileHandle.nullDevice
            let handle = pipe.fileHandleForReading

            state.withLock {
                $0.process = process
                $0.readHandle = handle
                $0.onLine = onLine
                $0.continuation = continuation
            }
            handle.readabilityHandler = { [self] handle in
                receive(handle.availableData)
            }
            process.terminationHandler = { [self] process in
                terminated(process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                handle.readabilityHandler = nil
                let continuation = state.withLock { state -> CheckedContinuation<ProcessOutcome, any Error>? in
                    defer { state.continuation = nil; state.onLine = nil }
                    return state.continuation
                }
                continuation?.resume(throwing: error)
                return
            }
            // Cancellation may have arrived before the process existed.
            if state.withLock({ $0.cancelled }) { cancel() }
        }

        func cancel() {
            let process = state.withLock { state -> Process? in
                state.cancelled = true
                return state.process
            }
            guard let process, process.isRunning else { return }
            process.terminate()
            // SIGKILL after a 2 s grace period if SIGTERM was ignored.
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        /// Runs on the pipe's serial handler queue, so chunks are processed one at a time and in order.
        /// Lines are parsed under the lock but delivered to `onLine` outside it, so a slow consumer never blocks
        /// `cancel()` or the exit handler.
        private func receive(_ data: Data) {
            let batch = state.withLock { state -> (lines: [String], onLine: @Sendable (String) -> Void)? in
                guard state.continuation != nil, !state.abandoned, let onLine = state.onLine else { return nil }
                state.delivering = true
                var lines: [String] = []
                if data.isEmpty {
                    state.readHandle?.readabilityHandler = nil
                    if let tail = takePartialLine(&state) { lines.append(tail) }
                } else {
                    state.buffer.append(data)
                    while let newline = state.buffer.firstIndex(of: 0x0A) {
                        lines.append(String(decoding: state.buffer[state.buffer.startIndex..<newline], as: UTF8.self))
                        state.buffer.removeSubrange(state.buffer.startIndex...newline)
                    }
                }
                state.lines.append(contentsOf: lines)
                return (lines, onLine)
            }
            guard let batch else { return }
            batch.lines.forEach(batch.onLine)
            state.withLock { state in
                state.delivering = false
                if data.isEmpty {
                    state.reachedEOF = true
                    finishIfDone(&state)
                } else if state.exitCode != nil {
                    // Measured from the end of delivery, so the cap only counts time the pipe sat idle.
                    armIdleTimer(&state)
                }
            }
        }

        private func terminated(_ status: Int32) {
            state.withLock { state in
                guard state.continuation != nil else { return }
                state.exitCode = status
                finishIfDone(&state)
                if state.continuation != nil { armIdleTimer(&state) }
            }
        }

        /// After the child exits, output is read until EOF. The only exception is a grandchild that inherited the
        /// pipe and keeps it open: if nothing arrives for 1 s while no delivery is running, stop waiting.
        /// Re-armed after every processed chunk.
        private func armIdleTimer(_ current: inout State) {
            current.idleGeneration += 1
            let generation = current.idleGeneration
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1)) { [self] in
                let batch = state.withLock { state -> (tail: String, onLine: @Sendable (String) -> Void)? in
                    guard state.continuation != nil, state.idleGeneration == generation, !state.delivering,
                        let onLine = state.onLine
                    else { return nil }
                    state.abandoned = true
                    state.delivering = true
                    state.readHandle?.readabilityHandler = nil
                    let tail = takePartialLine(&state)
                    if let tail { state.lines.append(tail) }
                    return (tail ?? "", onLine)
                }
                guard let batch else { return }
                if !batch.tail.isEmpty { batch.onLine(batch.tail) }
                state.withLock { state in
                    state.delivering = false
                    state.reachedEOF = true
                    finishIfDone(&state)
                }
            }
        }

        private func takePartialLine(_ state: inout State) -> String? {
            guard !state.buffer.isEmpty else { return nil }
            defer { state.buffer.removeAll() }
            return String(decoding: state.buffer, as: UTF8.self)
        }

        private func finishIfDone(_ state: inout State) {
            guard state.reachedEOF, let exitCode = state.exitCode, let continuation = state.continuation else { return }
            state.continuation = nil
            state.onLine = nil
            state.readHandle = nil
            continuation.resume(returning: ProcessOutcome(exitCode: exitCode, output: state.lines.joined(separator: "\n")))
        }
    }
}
