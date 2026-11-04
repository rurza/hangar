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

@Suite struct WorkerConfigurationWriteTests {
    @Test func writesAPrivateFileThatLoadsBack() throws {
        let directory = NSTemporaryDirectory() + "hangar-config-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/worker/config.json"
        let config = WorkerConfiguration(
            serverURL: URL(string: "http://mac-mini:8787")!, token: "secret-token", maxConcurrentJobs: 2,
            dataDirectory: "/var/hangar")
        try config.write(to: path)
        try config.write(to: path)  // rewriting keeps the mode

        func mode(_ path: String) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
        }
        #expect(try mode(path) == 0o600)
        #expect(try mode(directory + "/worker") == 0o700)
        #expect(try WorkerConfiguration.load(from: path) == config)
    }
}
