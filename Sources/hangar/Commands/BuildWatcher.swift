import ArgumentParser
import Foundation
import HangarClient
import HangarCore

/// Follows a build to its end: `/events` for prompt updates, plus a re-read of the build right away and every
/// `pollInterval`, which covers events sent before the subscription took and a dropped event stream (which is
/// not reopened; the poll carries on alone). Failed re-reads are retried with backoff; only after
/// `lostContactAfter` of consecutive failures does the watch give up, with the build's last known state.
struct BuildWatcher {
    let cli: CLI

    enum Outcome {
        case finished(Build)
        /// The server could not be read for `lostContactAfter`; the build was last seen in this state.
        case lostContact(Build)
    }

    private enum Update: Sendable {
        case build(Build)
        case job(Job)
        case lostContact
    }

    /// Prints step transitions as they happen and, if the build failed, the failed steps' last 40 log lines.
    func watch(_ build: Build, events: AsyncThrowingStream<ServerEvent, any Error>) async -> Outcome {
        var progress = BuildProgress(build: build)
        var failingSince: ContinuousClock.Instant?
        do {
            emit(progress.apply(try await cli.api.build(build.id), timeZone: cli.timeZone))
        } catch {
            failingSince = .now
        }

        if !progress.isFinished {
            var lost = false
            let (updates, continuation) = AsyncStream.makeStream(of: Update.self)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await event in events {
                            switch event {
                            case .build(let build): continuation.yield(.build(build))
                            case .job(let job): continuation.yield(.job(job))
                            case .machine: continue
                            }
                        }
                    } catch {}
                }
                group.addTask { [api = cli.api, context = cli.context, failingSince] in
                    await Self.poll(
                        api: api, buildID: build.id, interval: context.pollInterval, window: context.lostContactAfter,
                        failingSince: failingSince, updates: continuation)
                }
                for await update in updates {
                    switch update {
                    case .build(let snapshot): emit(progress.apply(snapshot, timeZone: cli.timeZone))
                    case .job(let job): emit(progress.apply(job, timeZone: cli.timeZone))
                    case .lostContact: lost = true
                    }
                    if lost || progress.isFinished { break }
                }
                group.cancelAll()
            }
            if lost { return .lostContact(progress.build) }
        }

        let finished = progress.build
        if finished.status == .failed { await printFailures(finished) }
        cli.print("Build \(finished.buildNumber) \(finished.status.rawValue).")
        return .finished(finished)
    }

    /// Re-reads the build every `interval`. While reads fail the delay doubles, up to 15 s (or `interval` if that
    /// is longer); once they have failed for `window` without a success in between, it reports lost contact.
    private static func poll(
        api: HangarAPI, buildID: UUID, interval: Duration, window: Duration,
        failingSince: ContinuousClock.Instant?, updates: AsyncStream<Update>.Continuation
    ) async {
        let clock = ContinuousClock()
        var failingSince = failingSince
        var delay = interval
        while true {
            do { try await clock.sleep(for: delay) } catch { return }
            do {
                updates.yield(.build(try await api.build(buildID)))
                failingSince = nil
                delay = interval
            } catch {
                if Task.isCancelled { return }
                let since = failingSince ?? clock.now
                failingSince = since
                if since.duration(to: clock.now) >= window {
                    updates.yield(.lostContact)
                    return
                }
                delay = min(delay * 2, max(interval, .seconds(15)))
            }
        }
    }

    /// Best effort: a log that cannot be read is a warning, so the exit code still reports the build.
    private func printFailures(_ build: Build) async {
        for job in build.jobs where job.status == .failed {
            let step = job.steps.first { $0.status == .failed }?.name
            let label = Format.label(job.action)
            cli.print("[\(label)] failed" + (step.map { " in \($0)" } ?? "") + (job.failureReason.map { ": \($0)" } ?? ""))
            let tail: [LogEntry]
            do {
                tail = try await cli.api.log(jobID: job.id, step: step, tail: 40)
            } catch {
                cli.printError("warning: could not read the log of [\(label)]: \(error)")
                continue
            }
            guard !tail.isEmpty else { continue }
            cli.print("Last \(tail.count) log lines\(step.map { " of \($0)" } ?? ""):")
            for entry in tail { cli.print(Format.logLine(entry, timeZone: cli.timeZone)) }
        }
    }

    private func emit(_ lines: [String]) {
        for line in lines { cli.print(line) }
    }

    /// Exit code 0 for a succeeded, queued or running build, 1 for a failed one, 2 for a cancelled one.
    static func exit(for status: BuildStatus) throws {
        switch status {
        case .failed: throw ExitCode.failure
        case .cancelled: throw ExitCode(2)
        case .queued, .running, .succeeded: return
        }
    }
}
