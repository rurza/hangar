import Testing

@testable import HangarCore

@Suite struct SchemeTestsTests {
    @Test func aSchemeHasTestsWhenItsTestActionListsTargetsOrAPlan() {
        #expect(SchemeTests.hasTests(schemeXML: #"<TestAction><Testables><TestableReference skipped = "NO">"#))
        #expect(SchemeTests.hasTests(schemeXML: #"<TestAction><TestPlans><TestPlanReference reference = "container:A.xctestplan">"#))
        #expect(!SchemeTests.hasTests(schemeXML: #"<TestAction shouldAutocreateTestPlan = "YES"></TestAction>"#))
    }

    @Test func sharedSchemeFilesAreFoundInAnyProjectButNotInIgnoredDirectories() {
        let paths = [
            "BatFi.xcodeproj/xcshareddata/xcschemes/BatFi.xcscheme",
            "LetsMove/LetsMove.xcodeproj/xcshareddata/xcschemes/BatFi.xcscheme",
            "Pods/Pods.xcodeproj/xcshareddata/xcschemes/BatFi.xcscheme",
            "BatFi.xcodeproj/xcshareddata/xcschemes/BatFi Beta.xcscheme",
        ]
        #expect(SchemeTests.sharedSchemeFiles(named: "BatFi", in: paths) == [
            "BatFi.xcodeproj/xcshareddata/xcschemes/BatFi.xcscheme",
            "LetsMove/LetsMove.xcodeproj/xcshareddata/xcschemes/BatFi.xcscheme",
        ])
    }

    @Test func aTestTargetJoinsItsProductsSchemeOrGetsItsOwn() {
        let package = """
            products: [.library(name: "AppShared", targets: ["AppShared"]), .executable(name: "Tool", targets: ["Tool"])],
            targets: [
                .testTarget(name: "AppSharedTests"),
                .testTarget(
                    name: "ToolTests"),
                .testTarget(name: "LicenseTokenTests"),
                .testTarget(name: "Checks"),
            ]
            """
        #expect(SchemeTests.generatedSchemesWithTests(packageSwift: package) == ["AppShared", "Tool", "LicenseTokenTests", "Checks"])
    }

    @Test func onlyASchemeFileWithoutTestsIsAProblem() {
        let path = "BatFi.xcodeproj/xcshareddata/xcschemes/BatFi.xcscheme"
        let problem = SchemeTests.problem(scheme: "BatFi", files: [path: "<TestAction></TestAction>"])
        #expect(problem?.contains("“BatFi” has no tests") == true)
        #expect(problem?.contains(path) == true)
        #expect(SchemeTests.problem(scheme: "BatFi", files: [:]) == nil)
        #expect(SchemeTests.problem(scheme: "BatFi", files: [path: "<TestAction></TestAction>", "B/" + path: "<TestableReference>"]) == nil)
    }
}
