import Foundation
import GRDB
import HangarCore

public struct BuildRepository: Sendable {
    let database: Database

    public init(database: Database) { self.database = database }

    public func inTransaction<T>(_ body: (GRDB.Database) throws -> T) throws -> T { try database.write(body) }

    // MARK: Builds

    public func insert(_ build: Build) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO builds (id, app_id, workflow, ref, "commit", build_number, status,
                                        pinned_machine_id, created_at, finished_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    build.id.uuidString, build.appID.uuidString, build.workflow, build.ref, build.commit,
                    build.buildNumber, build.status.rawValue, build.pinnedMachineID?.uuidString,
                    dbTime(build.createdAt), build.finishedAt.map(dbTime),
                ])
            for job in build.jobs {
                try db.execute(
                    sql: """
                        INSERT INTO jobs (id, build_id, action_json, status, machine_id, queue_note, failure_reason,
                                          steps_json, outputs_json, created_at, assigned_at, started_at, finished_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        job.id.uuidString, build.id.uuidString, try Self.json(job.action), job.status.rawValue,
                        job.machineID?.uuidString, job.queueNote, job.failureReason, try Self.json(job.steps),
                        try Self.json(job.outputs), dbTime(job.createdAt), job.assignedAt.map(dbTime),
                        job.startedAt.map(dbTime), job.finishedAt.map(dbTime),
                    ])
            }
        }
    }

    public func build(id: UUID) throws -> Build? {
        try database.read { db in try Self.build(db, id: id) }
    }

    /// Newest first; `appID` nil lists every app.
    public func builds(appID: UUID?, limit: Int) throws -> [Build] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM builds WHERE (?1 IS NULL OR app_id = ?1)
                    ORDER BY created_at DESC, build_number DESC LIMIT ?2
                    """,
                arguments: [appID?.uuidString, limit])
            return try rows.map { try Self.build($0, jobs: Self.jobs(db, buildID: $0["id"])) }
        }
    }

    public func inFlight(appID: UUID) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM builds WHERE app_id = ? AND status IN ('queued', 'running'))",
                arguments: [appID.uuidString]) ?? false
        }
    }

    /// Derives the build status from its jobs; stamps `finishedAt` once the status is terminal.
    @discardableResult
    public func refreshBuildStatus(buildID: UUID) throws -> Build {
        try database.write { db in
            guard let build = try Self.build(db, id: buildID) else {
                throw APIError(code: "build_not_found", message: "No build \(buildID.uuidString).")
            }
            guard !build.jobs.isEmpty else { return build }
            let status = BuildStatus.derived(from: build.jobs.map(\.status))
            var finishedAt = build.finishedAt
            if status == .succeeded || status == .failed || status == .cancelled, finishedAt == nil {
                finishedAt = build.jobs.compactMap(\.finishedAt).max() ?? Date()
            }
            try db.execute(
                sql: "UPDATE builds SET status = ?, finished_at = ? WHERE id = ?",
                arguments: [status.rawValue, finishedAt.map(dbTime), buildID.uuidString])
            return try Self.build(db, id: buildID)!
        }
    }

    // MARK: Jobs

    public func jobs(status: Set<JobStatus>) throws -> [Job] {
        guard !status.isEmpty else { return [] }
        return try database.read { db in
            let marks = Array(repeating: "?", count: status.count).joined(separator: ", ")
            return try Row.fetchAll(
                db, sql: "SELECT * FROM jobs WHERE status IN (\(marks)) ORDER BY created_at, id",
                arguments: StatementArguments(status.map(\.rawValue))
            ).map(Self.job)
        }
    }

    public func job(id: UUID) throws -> Job? {
        try database.read { db in try Self.job(db, id: id) }
    }

    /// True when this call moved the job from queued to assigned; a concurrent second call gets false.
    public func assign(jobID: UUID, to machineID: UUID, at date: Date) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE jobs SET status = 'assigned', machine_id = ?, assigned_at = ?
                    WHERE id = ? AND status = 'queued'
                    """,
                arguments: [machineID.uuidString, dbTime(date), jobID.uuidString])
            return db.changesCount == 1
        }
    }

    public func unassign(jobID: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE jobs SET status = 'queued', machine_id = NULL, assigned_at = NULL WHERE id = ?",
                arguments: [jobID.uuidString])
        }
    }

    /// `running` sets `startedAt`, a terminal status sets `finishedAt`.
    public func setJobStatus(id: UUID, status: JobStatus, at date: Date, failureReason: String? = nil) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE jobs SET status = ?1,
                        started_at = CASE WHEN ?1 = 'running' THEN ?2 ELSE started_at END,
                        finished_at = CASE WHEN ?1 IN ('succeeded', 'failed', 'cancelled') THEN ?2 ELSE finished_at END,
                        failure_reason = COALESCE(?3, failure_reason)
                    WHERE id = ?4
                    """,
                arguments: [status.rawValue, dbTime(date), failureReason, id.uuidString])
        }
    }

    public func setQueueNote(jobID: UUID, note: String?) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE jobs SET queue_note = ? WHERE id = ?", arguments: [note, jobID.uuidString])
        }
    }

    /// Updates the named step (or appends it), keeping insertion order.
    public func upsertStep(jobID: UUID, _ update: StepUpdate) throws {
        try database.write { db in
            guard let job = try Self.job(db, id: jobID) else { return }
            var steps = job.steps
            var step = steps.first { $0.name == update.name } ?? StepRecord(name: update.name, status: update.status)
            step.status = update.status
            switch update.status {
            case .running: step.startedAt = update.at
            case .succeeded, .failed, .skipped: step.finishedAt = update.at
            case .pending: break
            }
            if let index = steps.firstIndex(where: { $0.name == update.name }) {
                steps[index] = step
            } else {
                steps.append(step)
            }
            try db.execute(
                sql: "UPDATE jobs SET steps_json = ? WHERE id = ?", arguments: [try Self.json(steps), jobID.uuidString])
        }
    }

    public func setOutputs(jobID: UUID, _ outputs: [String: String]) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE jobs SET outputs_json = ? WHERE id = ?", arguments: [try Self.json(outputs), jobID.uuidString])
        }
    }

    // MARK: Build numbers

    /// Fails with a constraint error when the number is already reserved for the app.
    public func reserveNumber(appID: UUID, number: Int, buildID: UUID) throws {
        try database.write { db in try Self.reserveNumber(db, appID: appID, number: number, buildID: buildID) }
    }

    public func highestAssigned(appID: UUID) throws -> Int? {
        try database.read { db in try Self.highestAssigned(db, appID: appID) }
    }

    public func setHighestAssigned(appID: UUID, _ number: Int) throws {
        try database.write { db in try Self.setHighestAssigned(db, appID: appID, number) }
    }

    /// Variants for use inside `inTransaction`, so number reservation and build insertion commit together.
    public static func reserveNumber(_ db: GRDB.Database, appID: UUID, number: Int, buildID: UUID) throws {
        try db.execute(
            sql: "INSERT INTO build_numbers (app_id, number, build_id) VALUES (?, ?, ?)",
            arguments: [appID.uuidString, number, buildID.uuidString])
    }

    public static func highestAssigned(_ db: GRDB.Database, appID: UUID) throws -> Int? {
        try Int.fetchOne(
            db, sql: "SELECT highest_assigned FROM app_counters WHERE app_id = ?", arguments: [appID.uuidString])
    }

    public static func setHighestAssigned(_ db: GRDB.Database, appID: UUID, _ number: Int) throws {
        try db.execute(
            sql: """
                INSERT INTO app_counters (app_id, highest_assigned) VALUES (?, ?)
                ON CONFLICT (app_id) DO UPDATE SET highest_assigned = excluded.highest_assigned
                """,
            arguments: [appID.uuidString, number])
    }

    // MARK: Row mapping

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONCoding.encoder.encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONCoding.decoder.decode(type, from: Data(text.utf8))
    }

    private static func build(_ db: GRDB.Database, id: UUID) throws -> Build? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM builds WHERE id = ?", arguments: [id.uuidString])
        else { return nil }
        return try build(row, jobs: jobs(db, buildID: id.uuidString))
    }

    private static func build(_ row: Row, jobs: [Job]) throws -> Build {
        Build(
            id: UUID(uuidString: row["id"])!, appID: UUID(uuidString: row["app_id"])!, workflow: row["workflow"],
            ref: row["ref"], commit: row["commit"], buildNumber: row["build_number"],
            status: BuildStatus(rawValue: row["status"])!,
            pinnedMachineID: (row["pinned_machine_id"] as String?).flatMap(UUID.init(uuidString:)),
            createdAt: dbDate(row["created_at"] as Double), finishedAt: dbDate(row["finished_at"] as Double?),
            jobs: jobs)
    }

    private static func jobs(_ db: GRDB.Database, buildID: String) throws -> [Job] {
        try Row.fetchAll(
            db, sql: "SELECT * FROM jobs WHERE build_id = ? ORDER BY created_at, rowid", arguments: [buildID]
        ).map(job)
    }

    private static func job(_ db: GRDB.Database, id: UUID) throws -> Job? {
        try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id.uuidString]).map(job)
    }

    private static func job(_ row: Row) throws -> Job {
        Job(
            id: UUID(uuidString: row["id"])!, buildID: UUID(uuidString: row["build_id"])!,
            action: try decode(ArchiveAction.self, row["action_json"]),
            status: JobStatus(rawValue: row["status"])!,
            machineID: (row["machine_id"] as String?).flatMap(UUID.init(uuidString:)),
            steps: try decode([StepRecord].self, row["steps_json"]), queueNote: row["queue_note"],
            failureReason: row["failure_reason"], outputs: try decode([String: String].self, row["outputs_json"]),
            createdAt: dbDate(row["created_at"] as Double), assignedAt: dbDate(row["assigned_at"] as Double?),
            startedAt: dbDate(row["started_at"] as Double?), finishedAt: dbDate(row["finished_at"] as Double?))
    }
}
