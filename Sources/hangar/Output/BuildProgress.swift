import Foundation
import HangarCore

/// A watched build, merged from snapshots and events that may arrive out of order, and the step
/// transitions each update adds: `HH:MM:SS [scheme/platform] step status`. Statuses only move forward,
/// so a stale event that lands after a newer snapshot neither rewinds the build nor prints twice.
struct BuildProgress {
    private(set) var build: Build

    init(build: Build) {
        self.build = build
    }

    var isFinished: Bool { build.status != .queued && build.status != .running }

    mutating func apply(_ snapshot: Build, timeZone: TimeZone, now: Date = Date()) -> [String] {
        guard snapshot.id == build.id else { return [] }
        let lines = snapshot.jobs.flatMap { apply($0, timeZone: timeZone, now: now) }
        build.finishedAt = snapshot.finishedAt ?? build.finishedAt
        if snapshot.jobs.isEmpty, Self.rank(snapshot.status) > Self.rank(build.status) { build.status = snapshot.status }
        return lines
    }

    mutating func apply(_ job: Job, timeZone: TimeZone, now: Date = Date()) -> [String] {
        guard job.buildID == build.id else { return [] }
        let existing = build.jobs.firstIndex { $0.id == job.id }
        let known = existing.map { build.jobs[$0] }
        var lines: [String] = []
        var steps = known?.steps ?? []
        for step in job.steps {
            if let index = steps.firstIndex(where: { $0.name == step.name }) {
                guard Self.rank(step.status) > Self.rank(steps[index].status) else { continue }
                steps[index] = step
            } else {
                steps.append(step)
            }
            guard step.status != .pending else { continue }
            let at = (step.status == .running ? step.startedAt : step.finishedAt ?? step.startedAt) ?? now
            lines.append("\(Format.time(at, timeZone: timeZone)) [\(Format.label(job.action))] \(step.name) \(step.status.rawValue)")
        }
        var merged = known.map { Self.rank($0.status) > Self.rank(job.status) ? $0 : job } ?? job
        merged.steps = steps
        if let existing { build.jobs[existing] = merged } else { build.jobs.append(merged) }
        build.status = BuildStatus.derived(from: build.jobs.map(\.status))
        return lines
    }

    private static func rank(_ status: StepStatus) -> Int {
        switch status {
        case .pending: 0
        case .running: 1
        case .succeeded, .failed, .skipped: 2
        }
    }

    private static func rank(_ status: JobStatus) -> Int {
        switch status {
        case .queued: 0
        case .assigned: 1
        case .running: 2
        case .succeeded, .failed, .cancelled: 3
        }
    }

    private static func rank(_ status: BuildStatus) -> Int {
        switch status {
        case .queued: 0
        case .running: 1
        case .succeeded, .failed, .cancelled: 2
        }
    }
}
