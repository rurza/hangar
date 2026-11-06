import CryptoKit
import Foundation
import HangarCore
import Testing

@testable import HangarServer

@Suite struct VariableRepositoryTests {
    func make(path: String = ":memory:") throws -> (Database, VariableRepository, AppRepository) {
        let database = try Database(path: path)
        try database.migrate()
        let box = SecretBox(key: SymmetricKey(size: .bits256))
        return (database, VariableRepository(database: database, box: box), AppRepository(database: database))
    }

    func app(_ apps: AppRepository, _ name: String = "Demo") throws -> App {
        try apps.create(CreateAppRequest(name: name, repoURL: "https://example.com/r.git", appStoreConnectAppID: "1"))
    }

    @Test func appOverridesGlobal() throws {
        let (_, variables, apps) = try make()
        let demo = try app(apps)
        try variables.set(scope: .global, name: "A", input: VariableInput(value: "global-a"))
        try variables.set(scope: .global, name: "B", input: VariableInput(value: "global-b", isSecret: true))
        try variables.set(scope: .app(demo.id), name: "A", input: VariableInput(value: "app-a", asFile: true))
        // A global secret reaches only the apps that chose it.
        #expect(try variables.resolvedEntries(appID: demo.id, workflow: nil).map(\.name) == ["A"])
        try variables.grantGlobalSecret(appID: demo.id, name: "B")
        let entries = try variables.resolvedEntries(appID: demo.id, workflow: nil)
        #expect(entries == [
            EnvEntry(name: "A", value: "app-a", isSecret: false, asFile: true),
            EnvEntry(name: "B", value: "global-b", isSecret: true, asFile: false),
        ])
        #expect(try variables.value(global: "A") == "global-a")
        #expect(try variables.value(global: "missing") == nil)
    }

    @Test func plaintextNeverInDatabaseFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, variables, _) = try make(path: directory.appendingPathComponent("hangar.sqlite").path)
        try variables.set(scope: .global, name: "PLAIN", input: VariableInput(value: "hunter2-plaintext"))
        try variables.set(scope: .global, name: "SECRET", input: VariableInput(value: "hunter2-plaintext", isSecret: true))
        let needle = Data("hunter2-plaintext".utf8)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count >= 1)
        for file in files {
            #expect(try Data(contentsOf: file).range(of: needle) == nil)
        }
    }

    @Test func summariesCarryNoValue() throws {
        let (_, variables, _) = try make()
        try variables.set(scope: .global, name: "TOKEN", input: VariableInput(value: "s3cret", isSecret: true))
        let summaries = try variables.summaries(scope: .global)
        #expect(summaries.map(\.name) == ["TOKEN"])
        #expect(summaries[0].isSecret)
        #expect(!String(describing: summaries).contains("s3cret"))
    }

    @Test func rejectsInvalidNamesAndReplacesOnSet() throws {
        let (_, variables, _) = try make()
        #expect(throws: APIError.self) {
            try variables.set(scope: .global, name: "1BAD", input: VariableInput(value: "x"))
        }
        try variables.set(scope: .global, name: "OK_1", input: VariableInput(value: "one"))
        try variables.set(scope: .global, name: "OK_1", input: VariableInput(value: "two"))
        #expect(try variables.value(global: "OK_1") == "two")
        try variables.delete(scope: .global, name: "OK_1")
        #expect(try variables.summaries(scope: .global).isEmpty)
    }

    @Test func appRepositoryRules() throws {
        let (_, _, apps) = try make()
        let demo = try app(apps, "My App!")
        #expect(demo.slug == "my-app")
        #expect(throws: APIError(code: "app_exists", message: "An app with the slug 'my-app' already exists.")) {
            try app(apps, "my app")
        }
        #expect(throws: APIError.self) { try app(apps, "***") }
        #expect(try apps.find(slugOrID: "my-app") == demo)
        #expect(try apps.find(slugOrID: demo.id.uuidString) == demo)
        try apps.delete(id: demo.id)
        #expect(try apps.all().isEmpty)
    }
}
