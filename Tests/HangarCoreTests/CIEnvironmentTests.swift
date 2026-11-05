import Foundation
import Testing
@testable import HangarCore

@Suite struct CIEnvironmentTests {
    let app = App(
        id: UUID(), slug: "legilomobile", name: "LegiloMobile", repoURL: "https://github.com/x/y",
        appStoreConnectAppID: "123", createdAt: Date(timeIntervalSince1970: 0))
    let action = WorkflowAction(scheme: "LegiloMobile", platform: .iOS, export: .appStoreConnect)
    let paths = CIEnvironment.Paths(
        repository: "/w/repo", projectFile: "/w/repo/Legilo.xcodeproj", derivedData: "/w/DD",
        archive: "/j/archive/App.xcarchive", resultBundle: "/j/result.xcresult", workspace: "/j",
        temporary: "/var/folders/x/T/hangar-jobs/job-1")
    let jobID = UUID()
    let buildID = UUID()

    func make(
        ref: String = "main", teamID: String? = "TEAM123",
        processEnvironment: [String: String] = ["HOME": "/Users/hangar"]
    ) -> [String: String] {
        CIEnvironment.make(
            app: app, workflow: "Release", action: action, buildNumber: 311, jobID: jobID, buildID: buildID,
            commit: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", ref: ref, teamID: teamID, paths: paths,
            developerDir: "/Applications/Xcode.app/Contents/Developer", basePATH: "/usr/bin:/bin",
            processEnvironment: processEnvironment)
    }

    @Test func setsXcodeCloudVariablesForLegiloMobile() {
        let env = make()
        #expect(env["CI"] == "TRUE")
        #expect(env["CI_HANGAR"] == "TRUE")
        #expect(env["CI_XCODE_CLOUD"] == nil)
        #expect(env["CI_START_CONDITION"] == "manual")
        #expect(env["CI_XCODEBUILD_ACTION"] == "archive")
        #expect(env["CI_PRIMARY_REPOSITORY_PATH"] == "/w/repo")
        #expect(env["CI_WORKSPACE"] == "/j")
        #expect(env["CI_PROJECT_FILE_PATH"] == "/w/repo/Legilo.xcodeproj")
        #expect(env["CI_DERIVED_DATA_PATH"] == "/w/DD")
        #expect(env["CI_ARCHIVE_PATH"] == "/j/archive/App.xcarchive")
        #expect(env["CI_RESULT_BUNDLE_PATH"] == "/j/result.xcresult")
        #expect(env["CI_BUILD_NUMBER"] == "311")
        #expect(env["CI_BUILD_ID"] == jobID.uuidString)
        #expect(env["CI_WORKFLOW"] == "Release")
        #expect(env["CI_WORKFLOW_ID"] == "Release")
        #expect(env["CI_PRODUCT"] == "LegiloMobile")
        #expect(env["CI_PRODUCT_ID"] == "legilomobile")
        #expect(env["CI_PRODUCT_PLATFORM"] == "iOS")
        #expect(env["CI_XCODE_SCHEME"] == "LegiloMobile")
        #expect(env["CI_COMMIT"] == "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")
        #expect(env["CI_BRANCH"] == "main")
        #expect(env["CI_TEAM_ID"] == "TEAM123")
        #expect(env["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
        #expect(env["PATH"] == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        #expect(env["HOME"] == "/Users/hangar")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
    }

    @Test func testActionSetsTestVariablesAndNoArchivePath() {
        let env = CIEnvironment.make(
            app: app, workflow: "Tests", action: .test(scheme: "LegiloTests", platform: .iOS, testPlan: "Smoke"),
            buildNumber: 311, jobID: jobID, buildID: buildID, commit: "abc", ref: "main", teamID: nil, paths: paths,
            developerDir: "/X", basePATH: "/usr/bin",
            testDestination: TestDestination(
                xcodebuildDestination: "platform=iOS Simulator,id=ABC", deviceType: "iPhone 17", runtime: "iOS 27.2"),
            processEnvironment: [:])
        #expect(env["CI_XCODEBUILD_ACTION"] == "test")
        #expect(env["CI_ARCHIVE_PATH"] == nil)
        #expect(env["CI_RESULT_BUNDLE_PATH"] == "/j/result.xcresult")
        #expect(env["CI_TEST_DESTINATION_DEVICE_TYPE"] == "iPhone 17")
        #expect(env["CI_TEST_DESTINATION_RUNTIME"] == "iOS 27.2")
        #expect(env["CI_TEST_PLAN"] == "Smoke")
        #expect(env["CI_XCODE_SCHEME"] == "LegiloTests")
        #expect(make()["CI_TEST_PLAN"] == nil)
        #expect(make()["CI_TEST_DESTINATION_DEVICE_TYPE"] == nil)
    }

    @Test func passesIdentityAndLocaleThroughFromTheProcessEnvironment() {
        let env = make(processEnvironment: [
            "HOME": "/Users/hangar", "USER": "hangar", "LOGNAME": "hangar-l", "TMPDIR": "/var/folders/x/T/",
            "SHELL": "/bin/zsh", "LANG": "pl_PL.UTF-8", "LC_ALL": "pl_PL.UTF-8", "LC_CTYPE": "UTF-8", "SECRET": "no",
        ])
        #expect(env["USER"] == "hangar")
        #expect(env["LOGNAME"] == "hangar-l")
        // TMPDIR is the job's own, not the worker's.
        #expect(env["TMPDIR"] == "/var/folders/x/T/hangar-jobs/job-1")
        #expect(env["SHELL"] == "/bin/zsh")
        #expect(env["LANG"] == "pl_PL.UTF-8")
        #expect(env["LC_ALL"] == "pl_PL.UTF-8")
        #expect(env["LC_CTYPE"] == "UTF-8")
        #expect(env["SECRET"] == nil)
    }

    @Test func derivesUserFromNSUserNameWhenMissing() {
        let env = make(processEnvironment: [:])
        #expect(env["USER"] == NSUserName())
        #expect(env["LOGNAME"] == NSUserName())
        #expect(make(processEnvironment: ["USER": "a"])["LOGNAME"] == "a")
        #expect(env["TMPDIR"] == "/var/folders/x/T/hangar-jobs/job-1")
    }

    @Test func setsDefaultUTF8LanguageWhenMissing() {
        #expect(make(processEnvironment: [:])["LANG"] == "en_US.UTF-8")
        #expect(make(processEnvironment: ["LANG": ""])["LANG"] == "en_US.UTF-8")
    }

    @Test func appVariablesMayOverrideLocaleButNotIdentity() {
        let ci = make(processEnvironment: ["USER": "hangar", "TMPDIR": "/t/"])
        let merged = CIEnvironment.merge(
            ci: ci,
            entries: [
                EnvEntry(name: "LANG", value: "C", isSecret: false, asFile: false),
                EnvEntry(name: "USER", value: "evil", isSecret: false, asFile: false),
                EnvEntry(name: "TMPDIR", value: "/x", isSecret: false, asFile: false),
            ], secretsDirectory: "/s")
        #expect(merged.env["LANG"] == "C")
        #expect(merged.env["USER"] == "hangar")
        #expect(merged.env["TMPDIR"] == "/var/folders/x/T/hangar-jobs/job-1")
    }

    @Test func shaRefSetsNoBranch() {
        #expect(make(ref: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")["CI_BRANCH"] == nil)
        #expect(make(ref: "deadbeef")["CI_BRANCH"] == "deadbeef")
    }

    @Test func teamIDAbsentWhenUnknown() {
        #expect(make(teamID: nil)["CI_TEAM_ID"] == nil)
    }

    @Test func pathIsDeduplicatedKeepingFirstOccurrence() {
        let env = CIEnvironment.make(
            app: app, workflow: "Release", action: action, buildNumber: 1, jobID: jobID, buildID: buildID,
            commit: "c", ref: "main", teamID: nil, paths: paths, developerDir: "/D",
            basePATH: "/usr/local/bin:/usr/bin:/usr/bin:/opt/homebrew/bin", processEnvironment: [:])
        #expect(env["PATH"] == "/usr/local/bin:/usr/bin:/opt/homebrew/bin")
        #expect(env["HOME"] == nil)
    }

    @Test func postXcodebuildAdditionsAppStore() {
        let additions = CIEnvironment.postXcodebuildAdditions(
            exitCode: 0, action: action, exportedAppPath: "/j/export/App.ipa")
        #expect(additions == ["CI_XCODEBUILD_EXIT_CODE": "0", "CI_APP_STORE_SIGNED_APP_PATH": "/j/export/App.ipa"])
    }

    @Test func postXcodebuildAdditionsDeveloperID() {
        let devID = WorkflowAction(scheme: "Mac", platform: .macOS, export: .developerID)
        let additions = CIEnvironment.postXcodebuildAdditions(
            exitCode: 65, action: devID, exportedAppPath: "/j/export/Mac.app")
        #expect(additions == ["CI_XCODEBUILD_EXIT_CODE": "65", "CI_DEVELOPER_ID_SIGNED_APP_PATH": "/j/export/Mac.app"])
        #expect(CIEnvironment.postXcodebuildAdditions(exitCode: 65, action: devID, exportedAppPath: nil)
            == ["CI_XCODEBUILD_EXIT_CODE": "65"])
    }

    @Test func userVariablesCannotOverrideCI() {
        let merged = CIEnvironment.merge(
            ci: make(),
            entries: [
                EnvEntry(name: "CI_BUILD_NUMBER", value: "999-secret"),
                EnvEntry(name: "CI_CUSTOM", value: "x"),
                EnvEntry(name: "FOO", value: "bar"),
            ],
            secretsDirectory: "/j/secrets")
        #expect(merged.env["CI_BUILD_NUMBER"] == "311")
        #expect(merged.env["CI_CUSTOM"] == nil)
        #expect(merged.env["FOO"] == "bar")
        #expect(merged.warnings.count == 2)
        #expect(merged.warnings[0].contains("CI_BUILD_NUMBER"))
        #expect(merged.warnings[0].contains("names starting with CI_ are reserved"))
        #expect(!merged.warnings.joined().contains("999-secret"))
    }

    @Test func reservedNamesAreRefusedWithTheReason() {
        // HOME is reserved even when the worker's environment has none to pass through.
        let ci = make(processEnvironment: [:])
        #expect(ci["HOME"] == nil)
        let merged = CIEnvironment.merge(
            ci: ci,
            entries: ["PATH", "HOME", "DEVELOPER_DIR", "USER", "LOGNAME", "TMPDIR", "SHELL", "GIT_TERMINAL_PROMPT"].map {
                EnvEntry(name: $0, value: "x")
            },
            secretsDirectory: "/j/secrets")
        #expect(merged.env["HOME"] == nil)
        #expect(merged.env["PATH"] == ci["PATH"])
        #expect(merged.warnings.count == 8)
        #expect(merged.warnings[0] == "Ignoring variable PATH: Hangar sets PATH for every job "
            + "(reserved: CI_*, PATH, HOME, DEVELOPER_DIR, USER, LOGNAME, TMPDIR and SHELL)")
        #expect(!merged.warnings.joined().contains("names starting with CI_"))
    }

    @Test func asFileEntryBecomesPath() {
        let merged = CIEnvironment.merge(
            ci: [:],
            entries: [EnvEntry(name: "HANGAR_ASC_KEY_PATH", value: "-----BEGIN-----", isSecret: true, asFile: true)],
            secretsDirectory: "/j/secrets")
        #expect(merged.env["HANGAR_ASC_KEY_PATH"] == "/j/secrets/HANGAR_ASC_KEY_PATH")
        #expect(merged.filesToWrite.count == 1)
        #expect(merged.filesToWrite[0].path == "/j/secrets/HANGAR_ASC_KEY_PATH")
        #expect(merged.filesToWrite[0].contents == "-----BEGIN-----")
    }
}
