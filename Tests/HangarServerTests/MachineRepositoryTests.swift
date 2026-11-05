import Foundation
import GRDB
import HangarCore
import Testing

@testable import HangarServer

@Suite struct MachineRepositoryTests {
    @Test func tokenShownOnceAndHashed() throws {
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        let machines = MachineRepository(database: database)
        let (machine, token) = try machines.create(name: "mini", maxConcurrentJobs: 2)
        #expect(try machines.authenticate(token: token) == machine)
        #expect(try machines.authenticate(token: token + "x") == nil)
        let stored = try database.read { try String.fetchOne($0, sql: "SELECT token_hash FROM machines") }
        #expect(stored != nil && stored != token && stored?.count == 64)
        #expect(try machines.find(nameOrID: "mini") == machine)
        #expect(throws: APIError.self) { try machines.create(name: "mini") }
    }

    @Test func reportRoundTrips() throws {
        let database = try HangarServer.Database(path: ":memory:")
        try database.migrate()
        let machines = MachineRepository(database: database)
        let (machine, _) = try machines.create(name: "mini")
        let report = MachineReport(
            macOSVersion: "26.0", xcodes: [InstalledXcode(version: "27.2", build: "A1", path: "/Applications/Xcode.app")],
            chip: "M4", performanceCores: 4, memoryGB: 16, freeDiskGB: 120.5, onACPower: true, tools: ["git": "2.45"],
            canSignWithoutPrompt: true, runningJobIDs: [])
        let seen = Date(timeIntervalSince1970: 1_800_000_000.123)
        try machines.updateReport(id: machine.id, report: report, seenAt: seen)
        let loaded = try #require(try machines.find(nameOrID: machine.id.uuidString))
        #expect(loaded.report == report)
        #expect(loaded.lastSeenAt == seen)
        try machines.delete(id: machine.id)
        #expect(try machines.all().isEmpty)
    }

    @Test func pausedIsStoredAndMachinesFromBeforeV7AreNotPaused() throws {
        let database = try HangarServer.Database(path: ":memory:")
        try Migrations.migrator.migrate(database.pool, upTo: "v6")
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO machines (id, name, token_hash, max_concurrent_jobs, created_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [UUID().uuidString, "old", String(repeating: "0", count: 64), 1, 1_800_000_000])
        }
        try database.migrate()
        #expect(try database.read { try Migrations.migrator.appliedIdentifiers($0) }.contains("v7"))
        let machines = MachineRepository(database: database)
        let old = try #require(try machines.find(nameOrID: "old"))
        #expect(!old.paused)

        let paused = try #require(try machines.setPaused(id: old.id, true))
        #expect(paused.paused && paused.name == "old")
        #expect(try machines.find(nameOrID: "old")?.paused == true)
        #expect(try machines.setPaused(id: old.id, false)?.paused == false)
        #expect(try machines.setPaused(id: UUID(), true) == nil)
    }
}
