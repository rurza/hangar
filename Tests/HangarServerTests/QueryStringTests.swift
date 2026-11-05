import Foundation
import Testing

@testable import HangarServer

/// The web UI's query strings (Web/assets/query.js), run in JXA, and read back by the server's `FormQuery`.
@Suite(.timeLimit(.minutes(1))) struct QueryStringTests {
    static func run(_ expression: String) throws -> String {
        try WorkflowYAMLRoundTripTests.runJXA(json: "null", files: ["query.js"], expression)
    }

    @Test(arguments: ["UX Review Keep", "A+B", "R&D=1", "Wydanie łódź", "feature/a b+c", "100%"])
    func aNameRoundTripsToTheServer(name: String) throws {
        let json = String(decoding: try JSONEncoder().encode(name), as: UTF8.self)
        let query = try Self.run("queryString({ workflow: \(json), ref: 'main' })")
        #expect(!query.contains(" ") && !query.contains("+"))
        let decoded = FormQuery(query)
        #expect(decoded.get("workflow") == name)
        #expect(decoded.get("ref") == "main")
    }

    @Test func emptyValuesAreLeftOut() throws {
        #expect(try Self.run("withQuery('/builds', { limit: 20, app: null, step: undefined, x: false })") == "/builds?limit=20")
        #expect(try Self.run("withQuery('/builds', { app: null })") == "/builds")
        #expect(try Self.run("queryString({ a: '', b: 0 })") == "a=&b=0")
    }
}
