import Testing
@testable import HangarCore

struct StatusDerivationTests {
    @Test(arguments: [
        ([JobStatus.running, .queued], BuildStatus.running),
        ([.assigned, .succeeded], .running),
        ([.queued, .succeeded], .queued),
        ([.queued, .failed], .queued),
        ([.succeeded, .succeeded], .succeeded),
        ([.succeeded, .failed], .failed),
        ([.failed, .cancelled], .failed),
        ([.cancelled, .succeeded], .cancelled),
        ([.cancelled], .cancelled),
    ])
    func derivesBuildStatus(jobs: [JobStatus], expected: BuildStatus) {
        #expect(BuildStatus.derived(from: jobs) == expected)
    }

    @Test func terminalStatuses() {
        #expect(JobStatus.succeeded.isTerminal && JobStatus.failed.isTerminal && JobStatus.cancelled.isTerminal)
        #expect(!JobStatus.queued.isTerminal && !JobStatus.assigned.isTerminal && !JobStatus.running.isTerminal)
    }
}
