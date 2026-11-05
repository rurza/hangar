import Foundation
import Testing
@testable import HangarCore

private let legilo = """
version: 1
workflows:
  testflight:
    project: Legilo.xcodeproj
    xcode: "27.2"
    team: YL78V8PY6H
    tools: [brew]
    actions:
      - { scheme: Legilo, platform: macos, export: app-store-connect }
      - { scheme: LegiloMobile, platform: ios, export: app-store-connect }
    post-actions:
      - testflight:
          groups: [Internal]
"""

private func yaml(project: String = "project: A.xcodeproj", actions: String = "- { scheme: A, platform: ios, export: app-store-connect }", post: String = "- testflight", version: Int = 1) -> String {
    """
    version: \(version)
    workflows:
      testflight:
        \(project)
        xcode: "27.2"
        actions:
          \(actions)
        post-actions:
          \(post)
    """
}

@Suite struct WorkflowFileParserTests {
    @Test func parsesLegiloExample() throws {
        let file = try WorkflowFileParser.parse(legilo)
        let workflow = try #require(file.workflows["testflight"])
        #expect(file.version == 1)
        #expect(workflow.project == "Legilo.xcodeproj")
        #expect(workflow.workspace == nil)
        #expect(workflow.xcode == "27.2")
        #expect(workflow.teamID == "YL78V8PY6H")
        #expect(workflow.tools == ["brew"])
        #expect(workflow.actions == [
            WorkflowAction(scheme: "Legilo", platform: .macOS, export: .appStoreConnect),
            WorkflowAction(scheme: "LegiloMobile", platform: .iOS, export: .appStoreConnect),
        ])
        #expect(workflow.postActions == [
            PostActionSpec(name: "testflight", settings: ["groups": .array([.string("Internal")])], requiresApproval: false)
        ])
        #expect(workflow.projectOrWorkspacePath == "Legilo.xcodeproj")
        #expect(workflow.projectDirectory == ".")
    }

    @Test func bareStringPostAction() throws {
        let workflow = try #require(WorkflowFileParser.parse(yaml()).workflows["testflight"])
        #expect(workflow.postActions == [PostActionSpec(name: "testflight", settings: [:], requiresApproval: false)])
    }

    @Test func liftsRequiresApproval() throws {
        let post = "- testflight:\n            requires-approval: true\n            groups: [QA]"
        let workflow = try #require(WorkflowFileParser.parse(yaml(post: post)).workflows["testflight"])
        #expect(workflow.postActions == [
            PostActionSpec(name: "testflight", settings: ["groups": .array([.string("QA")])], requiresApproval: true)
        ])
    }

    @Test func rejectsUnknownPostAction() {
        #expect(throws: WorkflowFileError.unknownPostAction(name: "slack", workflow: "testflight")) {
            try WorkflowFileParser.parse(yaml(post: "- slack"))
        }
    }

    @Test func rejectsVersion2() {
        #expect(throws: WorkflowFileError.unsupportedVersion(2)) {
            try WorkflowFileParser.parse(yaml(version: 2))
        }
    }

    @Test func rejectsProjectAndWorkspace() {
        #expect(throws: WorkflowFileError.projectAndWorkspace(workflow: "testflight")) {
            try WorkflowFileParser.parse(yaml(project: "project: A.xcodeproj\n    workspace: A.xcworkspace"))
        }
    }

    @Test func rejectsNeitherProjectNorWorkspace() {
        #expect(throws: WorkflowFileError.noProject(workflow: "testflight")) {
            try WorkflowFileParser.parse(yaml(project: "team: X"))
        }
    }

    @Test func rejectsEmptyActions() {
        #expect(throws: WorkflowFileError.noActions(workflow: "testflight")) {
            try WorkflowFileParser.parse(yaml(actions: "[]"))
        }
    }

    @Test func rejectsNoWorkflows() {
        #expect(throws: WorkflowFileError.noWorkflows) {
            try WorkflowFileParser.parse("version: 1\nworkflows: {}")
        }
    }

    @Test func rejectsUnknownPlatform() {
        #expect(throws: WorkflowFileError.unknownPlatform("android")) {
            try WorkflowFileParser.parse(yaml(actions: "- { scheme: A, platform: android, export: app-store-connect }"))
        }
    }

    @Test func rejectsUnknownExportMethod() {
        #expect(throws: WorkflowFileError.unknownExportMethod("ad-hoc")) {
            try WorkflowFileParser.parse(yaml(actions: "- { scheme: A, platform: ios, export: ad-hoc }"))
        }
    }

    @Test func rejectsBadTestFlightSetting() {
        #expect {
            try WorkflowFileParser.parse(yaml(post: "- testflight:\n            groups: 3"))
        } throws: { error in
            guard case .invalidPostActionSettings(let name, _) = error as? WorkflowFileError else { return false }
            return name == "testflight"
        }
    }

    @Test func rejectsUnknownTestFlightKey() {
        #expect {
            try WorkflowFileParser.parse(yaml(post: "- testflight:\n            group: [A]"))
        } throws: { error in
            guard case .invalidPostActionSettings = error as? WorkflowFileError else { return false }
            return true
        }
    }

    @Test func testFlightDefaults() throws {
        let settings = try TestFlightSettings(settings: [:])
        #expect(settings.waitForProcessing)
        #expect(settings.processingTimeoutMinutes == 60)
        #expect(settings.groups.isEmpty)
        #expect(settings.whatToTest)
        #expect(!settings.submitForExternalReview)
    }

    @Test func testFlightReadsKebabKeys() throws {
        let settings = try TestFlightSettings(settings: [
            "wait-for-processing": .bool(false),
            "processing-timeout-minutes": .int(10),
            "groups": .array([.string("A")]),
            "what-to-test": .bool(false),
            "submit-for-external-review": .bool(true),
        ])
        #expect(!settings.waitForProcessing)
        #expect(settings.processingTimeoutMinutes == 10)
        #expect(settings.groups == ["A"])
        #expect(!settings.whatToTest)
        #expect(settings.submitForExternalReview)
    }

    @Test func invalidYAMLCarriesMessage() {
        #expect {
            try WorkflowFileParser.parse("version: [1\nworkflows: {")
        } throws: { error in
            guard case .invalidYAML(let message) = error as? WorkflowFileError else { return false }
            return !message.isEmpty
        }
    }

    @Test func projectInSubdirectory() throws {
        let workflow = try #require(WorkflowFileParser.parse(yaml(project: "project: iOS/Winyl.xcodeproj")).workflows["testflight"])
        #expect(workflow.projectDirectory == "iOS")
        #expect(workflow.projectOrWorkspacePath == "iOS/Winyl.xcodeproj")
    }

    @Test func workspaceIsAccepted() throws {
        let workflow = try #require(WorkflowFileParser.parse(yaml(project: "workspace: App.xcworkspace")).workflows["testflight"])
        #expect(workflow.projectOrWorkspacePath == "App.xcworkspace")
    }

    @Test func platformNames() {
        #expect(Platform.macOS.ciName == "macOS")
        #expect(Platform.iOS.genericDestination == "generic/platform=iOS")
        #expect(Platform.macOS.appStoreConnectPlatform == "MAC_OS")
        #expect(Platform.visionOS.appStoreConnectPlatform == "VISION_OS")
    }

    @Test func workflowJSONRoundTrips() throws {
        let workflow = try #require(WorkflowFileParser.parse(legilo).workflows["testflight"])
        let data = try JSONEncoder().encode(workflow)
        #expect(try JSONDecoder().decode(Workflow.self, from: data) == workflow)
    }

    private func invalidYAMLMessage(_ text: String) -> String? {
        do { _ = try WorkflowFileParser.parse(text); return nil }
        catch { if case .invalidYAML(let message) = error { return message } else { return nil } }
    }

    @Test func rejectsUnknownWorkflowKey() {
        let text = yaml().replacingOccurrences(of: "post-actions:", with: "post-action:")
        let message = invalidYAMLMessage(text)
        #expect(message?.contains("post-action") == true)
        #expect(message?.contains("testflight") == true)
    }

    @Test func rejectsUnknownActionKey() {
        let message = invalidYAMLMessage(yaml(actions: "- { scheme: A, platform: ios, export: app-store-connect, target: X }"))
        #expect(message?.contains("target") == true)
        #expect(message?.contains("testflight") == true)
    }

    @Test func rejectsUnquotedXcodeVersion() {
        let text = yaml().replacingOccurrences(of: "xcode: \"27.10\"", with: "xcode: 27.10")
            .replacingOccurrences(of: "xcode: \"27.2\"", with: "xcode: 27.10")
        let message = invalidYAMLMessage(text)
        #expect(message?.contains("quoted") == true)
        #expect(message?.contains("xcode") == true)
    }

    @Test func rejectsUnquotedTeam() {
        let text = yaml().replacingOccurrences(of: "    xcode:", with: "    team: 0123456789\n    xcode:")
        #expect(invalidYAMLMessage(text)?.contains("team") == true)
    }

    // MARK: Test actions

    @Test func flatFormIsStillAnArchive() throws {
        let workflow = try #require(WorkflowFileParser.parse(yaml()).workflows["testflight"])
        #expect(workflow.actions == [WorkflowAction(scheme: "A", platform: .iOS, export: .appStoreConnect)])
        #expect(workflow.actions[0].kind == .archive)
    }

    @Test func explicitArchiveAndTestForms() throws {
        let actions = """
            - archive: { scheme: A, platform: ios, export: developer-id }
                  - test: { scheme: ATests, platform: ios, destination: "iPhone 17 Pro", test-plan: Smoke }
                  - test: { scheme: Mac, platform: macos }
                  - test: { scheme: B, platform: visionos, destination: recommended }
            """
        let workflow = try #require(WorkflowFileParser.parse(yaml(actions: actions)).workflows["testflight"])
        #expect(workflow.actions == [
            WorkflowAction(scheme: "A", platform: .iOS, export: .developerID),
            .test(scheme: "ATests", platform: .iOS, destination: "iPhone 17 Pro", testPlan: "Smoke"),
            .test(scheme: "Mac", platform: .macOS),
            .test(scheme: "B", platform: .visionOS),
        ])
        #expect(workflow.actions.map(\.kind) == [.archive, .test, .test, .test])
    }

    @Test(arguments: [
        ("- test: { scheme: A, platform: ios, export: app-store-connect }", "export"),
        ("- { scheme: A, platform: ios, export: app-store-connect, destination: X }", "destination"),
        ("- archive: { scheme: A, platform: ios, export: app-store-connect, test-plan: P }", "test-plan"),
        ("- test: { scheme: A, platform: ios, flavour: x }", "flavour"),
        ("- test: { platform: ios }", "scheme"),
        ("- archive: { scheme: A, platform: ios }", "export"),
        ("- test: A", "map"),
        ("- { test: { scheme: A, platform: ios }, archive: { scheme: A, platform: ios, export: app-store-connect } }", "test"),
        ("- test: { scheme: A, platform: macos, destination: \"iPhone 17\" }", "macOS"),
    ])
    func rejectsInvalidActionCombinations(action: String, mentioned: String) {
        let message = invalidYAMLMessage(yaml(actions: action))
        #expect(message?.contains(mentioned) == true, "\(action): \(message ?? "parsed")")
    }

    @Test func testActionJSONRoundTripsAndOldJSONDecodesAsArchive() throws {
        let test = WorkflowAction.test(scheme: "T", platform: .iOS, destination: "iPhone 17", testPlan: "Smoke")
        let data = try JSONEncoder().encode(test)
        #expect(try JSONDecoder().decode(WorkflowAction.self, from: data) == test)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""kind":"test""#) && text.contains(#""testPlan":"Smoke""#) && !text.contains("export"))

        let old = Data(#"{"scheme":"A","platform":"ios","export":"app-store-connect"}"#.utf8)
        #expect(try JSONDecoder().decode(WorkflowAction.self, from: old)
            == WorkflowAction(scheme: "A", platform: .iOS, export: .appStoreConnect))
        let archiveWithoutExport = Data(#"{"kind":"archive","scheme":"A","platform":"ios"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkflowAction.self, from: archiveWithoutExport) }
    }

    @Test func writerEmitsTheTestForm() throws {
        var file = try WorkflowFileParser.parse(yaml())
        file.workflows["testflight"]?.actions.append(
            .test(scheme: "A Tests", platform: .iOS, destination: "iPhone 17 Pro", testPlan: "Smoke"))
        file.workflows["testflight"]?.actions.append(.test(scheme: "Mac", platform: .macOS))
        let text = WorkflowYAMLWriter.yaml(file)
        #expect(text.contains(#"      - test: { scheme: "A Tests", platform: ios, destination: "iPhone 17 Pro", test-plan: Smoke }"#))
        #expect(text.contains("      - test: { scheme: Mac, platform: macos }"))
        #expect(text.contains("      - { scheme: A, platform: ios, export: app-store-connect }"))
        #expect(try WorkflowFileParser.parse(text) == file)
    }

    @Test func stepNamesFollowTheKind() {
        #expect(StepName.sequence(for: WorkflowAction(scheme: "A", platform: .iOS, export: .appStoreConnect), postActions: ["testflight"]) == [
            "checkout", "post-clone", "pre-xcodebuild", "archive", "stamp", "export", "post-xcodebuild",
            "post-action:testflight", "upload-artifacts", "cleanup",
        ])
        #expect(StepName.sequence(for: .test(scheme: "A", platform: .iOS), postActions: ["testflight"]) == [
            "checkout", "post-clone", "pre-xcodebuild", "test", "post-xcodebuild", "upload-artifacts", "cleanup",
        ])
    }

    @Test func actionLabels() {
        #expect(WorkflowAction(scheme: "A", platform: .iOS, export: .appStoreConnect).kindLabel == "Archive – iOS")
        #expect(WorkflowAction.test(scheme: "A", platform: .visionOS).kindLabel == "Test – visionOS")
    }
}
