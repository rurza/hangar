import Foundation
import Testing

@testable import HangarWorker

@Suite struct WorkerConfigurationTests {
    static func write(_ text: String) throws -> String {
        let path = NSTemporaryDirectory() + "worker-\(UUID().uuidString).json"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func defaultsMaxConcurrentJobsToOne() throws {
        let path = try Self.write(#"{"serverURL":"https://hangar.example","token":"t","dataDirectory":"/var/hangar"}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = try WorkerConfiguration.load(from: path)
        #expect(config.maxConcurrentJobs == 1)
        #expect(config.serverURL.absoluteString == "https://hangar.example")
        #expect(config.dataDirectory == "/var/hangar")
    }

    @Test func missingAndInvalidFilesThrowClearErrors() throws {
        #expect(throws: WorkerConfiguration.LoadError.self) { try WorkerConfiguration.load(from: "/nonexistent/w.json") }
        let path = try Self.write("{not json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: WorkerConfiguration.LoadError.self) { try WorkerConfiguration.load(from: path) }
    }
}
