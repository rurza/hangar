import Foundation
import Synchronization

public struct ProcessCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// The complete environment of the child; nothing is inherited.
    public var environment: [String: String]
    public var currentDirectory: String?

    public init(
        executable: String, arguments: [String], environment: [String: String] = [:], currentDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
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
/// stdout and stderr are merged and delivered line by line, in order of arrival.
public protocol ProcessRunner: Sendable {
    func run(_ command: ProcessCommand, onLine: @Sendable (String) -> Void) async throws -> ProcessOutcome
}

/// Runs a real child process with Foundation `Process`.
///
/// An executable that is not an absolute path is resolved through `/usr/bin/env` using the child's own `PATH`.
/// On task cancellation the child gets SIGTERM, then SIGKILL after a grace period, and `CancellationError` is thrown.
public struct LiveProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ command: ProcessCommand, onLine: @Sendable (String) -> Void) async throws -> ProcessOutcome {
        try Task.checkCancellation()
        let session = Session()
        let outcome = try await withoutActuallyEscaping(onLine) { onLine in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    session.start(command, onLine: onLine, continuation: continuation)
                }
            } onCancel: {
                session.cancel()
            }
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
            process.standardError = pipe
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

        private func receive(_ data: Data) {
            state.withLock { state in
                guard state.continuation != nil else { return }
                if data.isEmpty {
                    state.readHandle?.readabilityHandler = nil
                    state.reachedEOF = true
                    flushPartialLine(&state)
                    finishIfDone(&state)
                    return
                }
                state.buffer.append(data)
                while let newline = state.buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: state.buffer[state.buffer.startIndex..<newline], as: UTF8.self)
                    state.buffer.removeSubrange(state.buffer.startIndex...newline)
                    emit(line, &state)
                }
            }
        }

        private func terminated(_ status: Int32) {
            let waitForDrain = state.withLock { state -> Bool in
                guard state.continuation != nil else { return false }
                state.exitCode = status
                finishIfDone(&state)
                return state.continuation != nil
            }
            guard waitForDrain else { return }
            // The pipe may stay open if a grandchild inherited it; give it 1 s to close, then stop waiting.
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1)) { [self] in
                state.withLock { state in
                    guard state.continuation != nil else { return }
                    state.readHandle?.readabilityHandler = nil
                    state.reachedEOF = true
                    flushPartialLine(&state)
                    finishIfDone(&state)
                }
            }
        }

        private func emit(_ line: String, _ state: inout State) {
            state.lines.append(line)
            state.onLine?(line)
        }

        private func flushPartialLine(_ state: inout State) {
            guard !state.buffer.isEmpty else { return }
            let line = String(decoding: state.buffer, as: UTF8.self)
            state.buffer.removeAll()
            emit(line, &state)
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
