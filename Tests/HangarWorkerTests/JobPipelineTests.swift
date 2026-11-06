import Clocks
import Foundation
import HangarCore
import Testing

@testable import HangarWorker

@Suite(.timeLimit(.minutes(1))) struct JobPipelineTests {
    struct Quoting: Error, CustomStringConvertible {
        var description: String
    }

    /// "Secrets never leave the machine unmasked": a failed step's detail, and its stages', are built from error
    /// descriptions (an App Store Connect response, a git URL with a token) and are masked like the log.
    @Test func aFailedStepsDetailIsMasked() async throws {
        let secret = "ghp_s3cr3t"
        let connection = FakeServerConnection()
        let masker = SecretMasker(secrets: [secret])
        let log = JobLog(jobID: UUID(), masker: masker, connection: connection, clock: ImmediateClock())
        var pipeline = JobPipeline(
            jobID: UUID(), connection: connection, log: log, clock: ImmediateClock(), cancelled: { false },
            masker: masker)

        await pipeline.step("upload") { () async throws -> Void in
            throw Quoting(description: "https://x-access-token:\(secret)@github.com/acme/demo.git refused")
        }
        await pipeline.report(
            "post-action testflight", .running, stages: [StepStage(name: "Upload", status: .failed, detail: "key \(secret)")])

        let failed = try #require(connection.lastUpdate(of: "upload"))
        #expect(failed.status == .failed)
        #expect(failed.detail == "https://x-access-token:[masked]@github.com/acme/demo.git refused")
        #expect(connection.updates.last?.stages?.first?.detail == "key [masked]")
        #expect(!connection.updates.contains { "\($0)".contains(secret) })
    }
}
