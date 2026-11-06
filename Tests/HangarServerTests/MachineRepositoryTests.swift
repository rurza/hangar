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

    /// The upgrade keeps every Mac that builds in VMs today building in VMs: its latest report has `vm`.
    @Test func machinesReportingVMBeforeTheFlagKeepVMBuilds() throws {
        let database = try HangarServer.Database(path: ":memory:")
        try Migrations.migrator.migrate(database.pool, upTo: "v10")
        let vm = #"{"macOSVersion":"26","xcodes":[],"chip":"M4","performanceCores":4,"memoryGB":16,"freeDiskGB":1,"onACPower":true,"tools":{},"canSignWithoutPrompt":true,"runningJobIDs":[],"vm":{"slots":1,"configuredSlots":1,"freeSlots":1,"storageFreeGB":200,"networkFilter":true}}"#
        let host = #"{"macOSVersion":"26","xcodes":[],"chip":"M4","performanceCores":4,"memoryGB":16,"freeDiskGB":1,"onACPower":true,"tools":{},"canSignWithoutPrompt":true,"runningJobIDs":[]}"#
        try database.write { db in
            for (name, report) in [("macbook", vm as String?), ("mini", host), ("new", nil)] {
                try db.execute(
                    sql: """
                        INSERT INTO machines (id, name, token_hash, max_concurrent_jobs, created_at, report_json)
                        VALUES (?, ?, ?, 1, 1800000000, ?)
                        """,
                    arguments: [UUID().uuidString, name, name + String(repeating: "0", count: 58), report])
            }
        }
        try database.migrate()
        let machines = MachineRepository(database: database)
        #expect(try machines.find(nameOrID: "macbook")?.vmBuilds == true)
        #expect(try machines.find(nameOrID: "mini")?.vmBuilds == false)
        #expect(try machines.find(nameOrID: "new")?.vmBuilds == false)
        let mini = try #require(try machines.find(nameOrID: "mini"))
        #expect(try machines.setVMBuilds(id: mini.id, true)?.vmBuilds == true)
        #expect(try machines.setVMBuilds(id: mini.id, false)?.vmBuilds == false)
    }

    @Test func onlyTheOwnerAllowsVMBuilds() async throws {
        let fixture = try APIFixture()
        let (machine, _) = try fixture.server.machines.create(name: "macbook")
        let (_, configure) = try fixture.server.apiTokens.create(name: "agent", scope: .configure)
        try await fixture.test { client in
            try await client.execute(
                uri: "/api/v1/machines/macbook/vm-builds", method: .post, headers: [.authorization: "Bearer \(configure)"]
            ) { #expect($0.status == .forbidden) }
            try await client.execute(uri: "/api/v1/machines/macbook/vm-builds", method: .post) { response in
                #expect(response.status == .ok)
                let machine = try decode(Machine.self, response)
                #expect(machine.vmBuilds)
            }
            try await client.execute(uri: "/api/v1/machines/macbook/vm-builds", method: .delete) { response in
                let machine = try decode(Machine.self, response)
                #expect(machine.vmBuilds == false)
            }
        }
        #expect(try fixture.server.machines.find(nameOrID: machine.id.uuidString)?.vmBuilds == false)
    }
}
