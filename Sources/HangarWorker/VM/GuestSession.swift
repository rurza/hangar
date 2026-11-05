import Foundation
import HangarCore
import Synchronization

/// A process whose standard input stays open: the job's SSH session, which gets the bundle and then control lines.
public protocol GuestSession: Sendable {
    /// Writes one line (a newline is added). Ignored once the process has ended.
    func send(_ line: SensitiveText)
    /// SIGTERM, then SIGKILL after two seconds.
    func terminate()
    /// The exit status, once the process has ended and its output is read.
    func wait() async -> Int32
}

public protocol GuestSessionLaunching: Sendable {
    /// Starts `command` (its `standardInput` is ignored); every output line goes to `onLine`.
    func launch(_ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void) throws -> any GuestSession
}

/// Foundation `Process` with pipes.
public struct LiveGuestSessionLauncher: GuestSessionLaunching {
    public init() {}

    public func launch(_ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void) throws -> any GuestSession {
        try LiveGuestSession(command, onLine: onLine)
    }
}

final class LiveGuestSession: GuestSession {
    private struct State {
        var buffer = Data()
        var exitCode: Int32?
        var reachedEOF = false
        var waiters: [CheckedContinuation<Int32, Never>] = []
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let state = Mutex(State())
    private let onLine: @Sendable (String) -> Void
    private let writeLock = Mutex(())

    init(_ command: ProcessCommand, onLine: @escaping @Sendable (String) -> Void) throws {
        self.onLine = onLine
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        // A write to a session that just ended must not kill the worker.
        signal(SIGPIPE, SIG_IGN)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
        process.terminationHandler = { [weak self] process in self?.ended(process.terminationStatus) }
        try process.run()
    }

    func send(_ line: SensitiveText) {
        writeLock.withLock { _ in
            guard state.withLock({ $0.exitCode == nil }) else { return }
            try? input.fileHandleForWriting.write(contentsOf: Data((line.value + "\n").utf8))
        }
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> Int32? in
                if state.reachedEOF, let code = state.exitCode { return code }
                state.waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    private func receive(_ data: Data) {
        var lines: [String] = []
        state.withLock { state in
            if data.isEmpty {
                output.fileHandleForReading.readabilityHandler = nil
                if !state.buffer.isEmpty { lines.append(String(decoding: state.buffer, as: UTF8.self)) }
                state.buffer.removeAll()
                state.reachedEOF = true
            } else {
                state.buffer.append(data)
                while let newline = state.buffer.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: state.buffer[state.buffer.startIndex..<newline], as: UTF8.self))
                    state.buffer.removeSubrange(state.buffer.startIndex...newline)
                }
            }
        }
        lines.forEach(onLine)
        if data.isEmpty { finishIfDone() }
    }

    private func ended(_ status: Int32) {
        state.withLock { $0.exitCode = status }
        try? input.fileHandleForWriting.close()
        // A grandchild holding the pipe open must not keep the job waiting.
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            guard let self else { return }
            state.withLock { $0.reachedEOF = true }
            finishIfDone()
        }
        finishIfDone()
    }

    private func finishIfDone() {
        let (waiters, code) = state.withLock { state -> ([CheckedContinuation<Int32, Never>], Int32) in
            guard state.reachedEOF, let code = state.exitCode else { return ([], 0) }
            defer { state.waiters = [] }
            return (state.waiters, code)
        }
        waiters.forEach { $0.resume(returning: code) }
    }
}
