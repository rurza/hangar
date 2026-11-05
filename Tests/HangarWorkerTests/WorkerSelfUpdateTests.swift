import Foundation
import HangarCore
import Testing

@testable import HangarWorker

@Suite struct WorkerSelfUpdateTests {
    @Test func stagesAMatchingBinaryAndRefusesAnyOther() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("hangar-worker")
        try Data("old".utf8).write(to: executable)
        let data = Data("new-worker".utf8)
        let hash = SHA256File.hex(of: data)

        #expect(throws: WorkerSelfUpdate.Failure.hashMismatch) {
            try WorkerSelfUpdate.stage(data, sha256: String(repeating: "0", count: 64), nextTo: executable)
        }
        let staged = try WorkerSelfUpdate.stage(data, sha256: hash, nextTo: executable)
        try WorkerSelfUpdate.replace(executable, with: staged)
        #expect(try Data(contentsOf: executable) == data)
        #expect(FileManager.default.fileExists(atPath: staged.path) == false)
    }

    @Test func binaryURLIsTheInstallEndpoint() {
        let url = WorkerSelfUpdate.binaryURL(server: URL(string: "http://mini:8789")!)
        #expect(url == URL(string: "http://mini:8789/install/hangar-worker"))
    }
}
