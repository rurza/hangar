import Foundation
import Testing
@testable import HangarWorker

@Suite struct WorkspaceLayoutTests {
    @Test func jobTemporaryDirectoryLivesUnderTheGivenRootByJobID() {
        let id = UUID()
        let layout = WorkspaceLayout(
            dataDirectory: "/data", appSlug: "demo", jobID: id, temporaryRoot: "/var/folders/x/T/hangar-jobs")
        #expect(layout.temporary == "/var/folders/x/T/hangar-jobs/" + id.uuidString)
        #expect(layout.temporaryRoot == "/var/folders/x/T/hangar-jobs")
    }

    @Test func defaultTemporaryRootIsInTheUserTempDirectoryWithoutSpaces() {
        let root = WorkspaceLayout.systemTemporaryRoot
        #expect(root.hasSuffix("/hangar-jobs"))
        #expect(!root.contains(" "))
        #expect(root.hasPrefix("/"))
        let layout = WorkspaceLayout(
            dataDirectory: "/Users/x/Library/Application Support/Hangar/worker", appSlug: "demo", jobID: UUID())
        #expect(!layout.temporary.contains("Application Support"))
        #expect(layout.temporary.hasPrefix(root + "/"))
    }
}
