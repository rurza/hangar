import Foundation
import Testing

/// What the app page and the Deploy sheet say a workflow does (Web/assets/workflow-summary.js), run in JXA.
@Suite(.timeLimit(.minutes(1))) struct WorkflowSummaryTests {
    static func run(_ workflow: String, _ expression: String) throws -> String {
        try WorkflowYAMLRoundTripTests.runJXA(json: workflow, files: ["workflow-summary.js"], expression)
    }

    static func steps(_ workflow: String) throws -> String { try run(workflow, "workflowSteps(input).join(' | ')") }
    static func summary(_ workflow: String) throws -> String { try run(workflow, "workflowSummary(input)") }

    static let archives = #"""
        {"xcode": "27.2", "tools": [], "actions": [
          {"kind": "archive", "scheme": "Legilo", "platform": "macos", "export": "app-store-connect"},
          {"kind": "archive", "scheme": "LegiloMobile", "platform": "ios", "export": "app-store-connect"}],
         "postActions": []}
        """#

    @Test func archivesWithoutUploadSayFilesOnly() throws {
        #expect(try Self.steps(Self.archives)
            == "Archives Legilo (macOS) and LegiloMobile (iOS) with Xcode 27.2. | Uploads nothing: the .ipa or .pkg is on the build page to download.")
        #expect(try Self.summary(Self.archives) == "Archives Legilo (macOS) and LegiloMobile (iOS) · Download only")
    }

    @Test func testFlightNamesItsGroups() throws {
        let workflow = Self.archives.replacingOccurrences(
            of: #""postActions": []"#,
            with: #""postActions": [{"name": "testflight", "settings": {"groups": ["Internal", "QA"]}, "requiresApproval": false}]"#)
        #expect(try Self.steps(workflow).hasSuffix("Uploads both to TestFlight for Internal and QA."))
        #expect(try Self.summary(workflow).hasSuffix("· TestFlight: Internal and QA"))
    }

    @Test func testFlightWithoutGroupsOrWaitingSaysWhoCanInstall() throws {
        let workflow = Self.archives.replacingOccurrences(
            of: #""postActions": []"#,
            with: #""postActions": [{"name": "testflight", "settings": {"groups": ["Internal"], "wait-for-processing": false}, "requiresApproval": false}]"#)
        #expect(try Self.steps(workflow).hasSuffix(
            "Uploads both to TestFlight, where App Store Connect users with access can install them."))
        #expect(try Self.summary(workflow).hasSuffix("· TestFlight"))
    }

    @Test func developerIDOnlyIsADownload() throws {
        let workflow = #"""
            {"xcode": "27.2", "tools": [], "actions": [
              {"kind": "archive", "scheme": "Legilo", "platform": "macos", "export": "developer-id"}],
             "postActions": [{"name": "testflight", "settings": {}, "requiresApproval": false}]}
            """#
        #expect(try Self.steps(workflow)
            == "Archives Legilo (macOS) with Xcode 27.2. | Exports a Developer ID app to download from the build page.")
        #expect(try Self.summary(workflow) == "Archives Legilo (macOS) · Download only")
    }

    @Test func testsOnlyAndMixedWorkflows() throws {
        let tests = #"""
            {"xcode": "27.2", "tools": [], "actions": [
              {"kind": "test", "scheme": "LegiloTests", "platform": "ios"}], "postActions": []}
            """#
        #expect(try Self.steps(tests) == "Tests LegiloTests (iOS) with Xcode 27.2.")
        #expect(try Self.summary(tests) == "Tests LegiloTests (iOS)")
        let mixed = #"""
            {"xcode": "27.2", "tools": [], "actions": [
              {"kind": "test", "scheme": "LegiloTests", "platform": "ios"},
              {"kind": "archive", "scheme": "Legilo", "platform": "macos", "export": "app-store-connect"}],
             "postActions": [{"name": "testflight", "settings": {}, "requiresApproval": false}]}
            """#
        #expect(try Self.steps(mixed)
            == "Tests LegiloTests (iOS). | Archives Legilo (macOS) with Xcode 27.2. | Uploads it to TestFlight, where App Store Connect users with access can install it.")
        #expect(try Self.summary(mixed) == "Tests LegiloTests (iOS) · Archives Legilo (macOS) · TestFlight")
    }

    @Test func listsReadAsSentences() throws {
        #expect(try Self.run("[]", "[listText([]), listText(['a']), listText(['a', 'b']), listText(['a', 'b', 'c'])].join('|')")
            == "|a|a and b|a, b and c")
    }
}
