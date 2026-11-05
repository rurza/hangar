import Foundation
import HangarCore
import Testing

@testable import HangarWorker

@Suite(.timeLimit(.minutes(1))) struct TestStepTests {
    private static let jobID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let layout = WorkspaceLayout(dataDirectory: "/data", appSlug: "legilo", jobID: jobID)
    private static let developerDir = "/Applications/Xcode-27.2.app/Contents/Developer"

    @Test func simulatorCommandWithPlanAndKey() {
        let action = WorkflowAction.test(scheme: "LegiloTests", platform: .iOS, testPlan: "Smoke")
        let workflow = Workflow(workspace: "Legilo.xcworkspace", xcode: "27.2", actions: [action])
        let key = ASCKeyArguments(keyPath: "/k.p8", keyID: "KEY", issuerID: "ISS")
        let command = TestStep.command(
            workflow: workflow, action: action, repository: Self.layout.repository, layout: Self.layout,
            developerDir: Self.developerDir,
            destination: TestDestination(xcodebuildDestination: "platform=iOS Simulator,id=ABC"),
            key: key, environment: ["PATH": "/usr/bin"])
        #expect(command.executable == "/usr/bin/xcodebuild")
        #expect(command.arguments == [
            "test", "-workspace", "/data/workspaces/legilo/repository/Legilo.xcworkspace",
            "-scheme", "LegiloTests", "-destination", "platform=iOS Simulator,id=ABC", "-testPlan", "Smoke",
            "-derivedDataPath", "/data/workspaces/legilo/DerivedData",
            "-resultBundlePath", "/data/jobs/00000000-0000-0000-0000-000000000001/result.xcresult",
            "-allowProvisioningUpdates", "-skipMacroValidation", "-skipPackagePluginValidation",
            "-disableAutomaticPackageResolution",
            "-authenticationKeyPath", "/k.p8", "-authenticationKeyID", "KEY", "-authenticationKeyIssuerID", "ISS",
        ])
        #expect(command.environment == ["PATH": "/usr/bin", "DEVELOPER_DIR": Self.developerDir])
    }

    @Test func summaryCommand() {
        let command = TestStep.summaryCommand(layout: Self.layout, developerDir: Self.developerDir, environment: [:])
        #expect(command.executable == "/usr/bin/xcrun")
        #expect(command.arguments == [
            "xcresulttool", "get", "test-results", "summary",
            "--path", "/data/jobs/00000000-0000-0000-0000-000000000001/result.xcresult", "--compact",
        ])
        #expect(command.environment["DEVELOPER_DIR"] == Self.developerDir)
    }

    @Test func failureReasons() {
        #expect(TestError.testsFailed(count: 3, exitCode: 65).description == "3 tests failed")
        #expect(TestError.testsFailed(count: 1, exitCode: 65).description == "1 test failed")
    }
}
