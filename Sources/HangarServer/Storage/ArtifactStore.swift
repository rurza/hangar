import Foundation
import HangarCore
import Hummingbird

/// Job artifacts at `jobs/<jobID>/artifacts/<name>`.
public struct ArtifactStore: Sendable {
    let jobsDirectory: URL

    public init(jobsDirectory: URL) { self.jobsDirectory = jobsDirectory }

    /// Streams to a temporary file and renames it into place, so a reader never sees a partial artifact.
    @discardableResult
    public func write<Chunks: AsyncSequence>(jobID: UUID, name: String, stream: Chunks) async throws -> URL
    where Chunks.Element == ByteBuffer {
        let destination = try url(jobID: jobID, name: name)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A leading dot is never a valid artifact name, so `list` cannot pick up a temporary file.
        let temporary = directory.appendingPathComponent(".upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            for try await chunk in stream { try handle.write(contentsOf: Data(chunk.readableBytesView)) }
            try handle.synchronize()
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return destination
    }

    /// Sorted by name; empty when the job has none.
    public func list(jobID: UUID) throws -> [ArtifactInfo] {
        let directory = self.directory(jobID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { url in
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { return nil }
                return ArtifactInfo(name: url.lastPathComponent, sizeBytes: values.fileSize ?? 0)
            }
            .sorted { $0.name < $1.name }
    }

    /// Where the artifact lives (or would live); throws for a name that could leave the job's directory.
    public func url(jobID: UUID, name: String) throws -> URL {
        guard Self.isValid(name: name) else {
            throw APIError(code: "invalid_artifact_name", message: "'\(name)' is not a valid artifact name.")
        }
        return directory(jobID).appendingPathComponent(name)
    }

    static func isValid(name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains("..")
            && !name.contains("\0")
    }

    private func directory(_ jobID: UUID) -> URL {
        jobsDirectory.appendingPathComponent(jobID.uuidString).appendingPathComponent("artifacts")
    }
}
