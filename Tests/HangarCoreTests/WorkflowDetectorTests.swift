import Foundation
import Testing

@testable import HangarCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func machine(_ name: String, xcodes: [String], online: Bool) -> Machine {
    Machine(
        id: UUID(), name: name, lastSeenAt: online ? now : now.addingTimeInterval(-3600),
        report: MachineReport(
            macOSVersion: "27.0", xcodes: xcodes.map { InstalledXcode(version: $0, build: "x", path: "/Applications/Xcode-\($0).app") },
            chip: "M4", performanceCores: 4, memoryGB: 16, freeDiskGB: 100, onACPower: true, tools: [:],
            canSignWithoutPrompt: true, runningJobIDs: []),
        createdAt: now)
}

/// A repository: its file listing plus the contents of the text files the detector may ask for.
private struct Fixture {
    var files: [String: String]
    var others: [String] = []

    var tree: RepositoryTree {
        var paths = Set(others)
        for path in Array(files.keys) + others {
            // The tree lists every directory too, as GitHub's recursive tree does.
            var parts = path.split(separator: "/").map(String.init)
            while !parts.isEmpty {
                paths.insert(parts.joined(separator: "/"))
                parts.removeLast()
            }
        }
        return RepositoryTree(paths: paths.sorted())
    }

    /// Asks for files the way the server does: rounds of `filesToFetch` until it wants nothing new.
    func detect(machines: [Machine] = [], requests: inout Int) throws(WorkflowDetectionError) -> WorkflowSuggestion {
        var fetched: [String: String] = [:]
        var asked = Set<String>()
        for _ in 0..<WorkflowDetector.maxFetchRounds {
            let wanted = WorkflowDetector.filesToFetch(tree: tree, files: fetched).filter { !asked.contains($0) }
                .prefix(WorkflowDetector.maxFileFetches - asked.count)
            if wanted.isEmpty { break }
            for path in wanted {
                asked.insert(path)
                requests += 1
                if let text = files[path] { fetched[path] = text }
            }
        }
        return try WorkflowDetector.suggest(tree: tree, files: fetched, machines: machines, now: now, commit: "abc123")
    }

    func detect(machines: [Machine] = []) throws(WorkflowDetectionError) -> WorkflowSuggestion {
        var requests = 0
        return try detect(machines: machines, requests: &requests)
    }
}

private func pbxproj(
    targets: [(id: String, name: String, type: String, sdk: String, team: String?)], bundleIDs: [String: String] = [:],
    configFiles: [String: String] = [:], supportedPlatforms: [String: String] = [:]
) -> String {
    var objects = ""
    for (name, file) in configFiles {
        objects += "\t\tF\(name) /* \(file) */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = \(file); sourceTree = \"<group>\"; };\n"
    }
    for target in targets {
        objects += """
            \t\t\(target.id) /* \(target.name) */ = {
            \t\t\tisa = PBXNativeTarget;
            \t\t\tbuildConfigurationList = \(target.id)L /* Build configuration list for PBXNativeTarget "\(target.name)" */;
            \t\t\tname = \(target.name);
            \t\t\tproductName = \(target.name);
            \t\t\tproductType = "com.apple.product-type.\(target.type)";
            \t\t};
            \t\t\(target.id)L = {
            \t\t\tisa = XCConfigurationList;
            \t\t\tbuildConfigurations = (\(target.id)D /* Debug */, \(target.id)R /* Release */, );
            \t\t};

            """
        for config in ["D", "R"] {
            objects += """
                \t\t\(target.id)\(config) = {
                \t\t\tisa = XCBuildConfiguration;
                \(configFiles[target.name].map { _ in "\t\t\tbaseConfigurationReference = F\(target.name);\n" } ?? "")                \t\t\tbuildSettings = {
                \t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
                \(bundleIDs[target.name].map { "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = \"\($0)\";\n" } ?? "")                \(target.team.map { "\t\t\t\tDEVELOPMENT_TEAM = \($0);\n" } ?? "")\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
                \t\t\t\tSDKROOT = \(target.sdk);\(supportedPlatforms[target.name].map { "\n\t\t\t\tSUPPORTED_PLATFORMS = \"\($0)\";" } ?? "")
                \t\t\t};
                \t\t\tname = \(config == "D" ? "Debug" : "Release");
                \t\t};

                """
        }
    }
    return """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 77;
        \tobjects = {
        \(objects)\t\tP0 /* Project object */ = {
        \t\t\tisa = PBXProject;
        \t\t\ttargets = (\(targets.map(\.id).joined(separator: ", ")), );
        \t\t};
        \t};
        \trootObject = P0 /* Project object */;
        }

        """
}

private func xcscheme(blueprint: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme LastUpgradeVersion = "2700" version = "1.7">
       <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
          <BuildActionEntries>
             <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES">
                <BuildableReference
                   BuildableIdentifier = "primary"
                   BlueprintIdentifier = "T9"
                   BuildableName = "\(blueprint).app"
                   BlueprintName = "\(blueprint)"
                   ReferencedContainer = "container:BatFi.xcodeproj">
                </BuildableReference>
             </BuildActionEntry>
          </BuildActionEntries>
       </BuildAction>
    </Scheme>
    """
}

private let macIconSet = """
    {
      "images" : [
        { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
        { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
        { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" },
        { "idiom" : "mac", "scale" : "2x", "size" : "256x256" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """

private let iosIconSet = """
    {
      "images" : [
        { "filename" : "AppIcon-60@3x.png", "idiom" : "iphone", "scale" : "3x", "size" : "60x60" },
        { "filename" : "AppIcon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """

private let legiloProjectYML = """
    name: Legilo
    options:
      bundleIdPrefix: software.micropixels
    settings:
      base:
        DEVELOPMENT_TEAM: YL78V8PY6H
    targets:
      LegiloTests:
        type: bundle.unit-test
        platform: macOS
        sources: [LegiloTests]
      Legilo:
        type: application
        platform: macOS
        sources: [Legilo]
      LegiloMobile:
        type: application
        platform: iOS
        sources:
          - path: LegiloMobile
    schemes:
      Legilo:
        build:
          targets:
            Legilo: all
        test:
          targets: [LegiloTests]
      LegiloMobile:
        build:
          targets:
            LegiloMobile: all
    """

private let legilo = Fixture(
    files: [
        "project.yml": legiloProjectYML,
        "ci_scripts/ci_post_clone.sh": "#!/bin/sh\nset -e\ncd \"$CI_PRIMARY_REPOSITORY_PATH\"\nmint run xcodegen generate\n",
        "Legilo/Assets.xcassets/AppIcon.appiconset/Contents.json": macIconSet,
        "LegiloMobile/Assets.xcassets/AppIcon.appiconset/Contents.json": iosIconSet,
    ],
    others: [
        "Legilo/Assets.xcassets/AppIcon.appiconset/icon_16x16.png",
        "Legilo/Assets.xcassets/AppIcon.appiconset/icon_512x512.png",
        "Legilo/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png",
        "LegiloMobile/Assets.xcassets/AppIcon.appiconset/AppIcon-60@3x.png",
        "LegiloMobile/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
        "Legilo/LegiloApp.swift", "LegiloTests/LegiloTests.swift", "README.md",
    ])

private let batFi = Fixture(
    files: [
        "BatFi.xcodeproj/project.pbxproj": pbxproj(targets: [
            ("T1", "BatFi", "application", "macosx", "ABCDE12345"),
            ("T2", "BatFiKit", "framework", "macosx", "ABCDE12345"),
            ("T3", "CompanionApp", "application", "iphoneos", "ABCDE12345"),
            ("T4", "BatFiTests", "bundle.unit-test", "macosx", "ZZZZZ99999"),
        ], bundleIDs: [
            "BatFi": "software.micropixels.$(PRODUCT_NAME:rfc1034identifier)", "CompanionApp": "$(BASE_ID).companion",
            "BatFiKit": "software.micropixels.kit",
        ]),
        "BatFi.xcodeproj/xcshareddata/xcschemes/Companion.xcscheme": xcscheme(blueprint: "CompanionApp"),
        "BatFi/Assets.xcassets/AppIcon.appiconset/Contents.json": macIconSet,
    ],
    others: [
        "BatFi.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
        "BatFi.xcodeproj/xcshareddata/xcschemes/BatFi.xcscheme",
        "BatFi.xcodeproj/xcshareddata/xcschemes/BatFiKit.xcscheme",
        "BatFi.xcodeproj/xcshareddata/xcschemes/BatFiTests.xcscheme",
        "BatFi/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png",
        "BatFi/Assets.xcassets/AppIcon.appiconset/icon_16x16.png",
        "BatFi/Assets.xcassets/AppIcon.appiconset/icon_512x512.png",
        "BatFi/App.swift",
    ])

@Suite struct WorkflowDetectorTests {
    @Test func xcodeGenProject() throws {
        var requests = 0
        let suggestion = try legilo.detect(
            machines: [machine("mini", xcodes: ["26.4", "27.2.1"], online: true), machine("old", xcodes: ["28.0"], online: false)],
            requests: &requests)
        let workflow = try #require(suggestion.workflows.workflows["release"])
        #expect(workflow.project == "Legilo.xcodeproj")
        #expect(workflow.workspace == nil)
        #expect(workflow.teamID == "YL78V8PY6H")
        #expect(workflow.tools == ["xcodegen"])
        #expect(workflow.xcode == "27.2")
        #expect(workflow.postActions.isEmpty)
        #expect(workflow.actions == [
            WorkflowAction(scheme: "Legilo", platform: .macOS, export: .appStoreConnect),
            WorkflowAction(scheme: "LegiloMobile", platform: .iOS, export: .appStoreConnect),
        ])
        #expect(suggestion.schemes == [
            DetectedScheme(name: "Legilo", platform: .macOS, isApplication: true, hasTests: true),
            DetectedScheme(name: "LegiloMobile", platform: .iOS, isApplication: true),
        ])
        #expect(suggestion.projects == ["Legilo.xcodeproj"])
        #expect(suggestion.commit == "abc123")
        #expect(suggestion.notes.contains { $0.contains("ci_post_clone.sh") && $0.contains("XcodeGen") })
        #expect(suggestion.notes.contains { $0.contains("project.yml") })
        #expect(suggestion.icon == DetectedIcon(path: "Legilo/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png", kind: .appiconset))
        #expect(try WorkflowFileParser.parse(suggestion.yaml) == suggestion.workflows)
        #expect(requests <= WorkflowDetector.maxFileFetches)
    }

    @Test func xcodeGenWithoutPostCloneRunningIt() throws {
        var fixture = legilo
        fixture.files["ci_scripts/ci_post_clone.sh"] = "#!/bin/sh\nbrew install swiftlint\n"
        let suggestion = try fixture.detect()
        let workflow = try #require(suggestion.workflows.workflows["release"])
        #expect(workflow.tools == ["xcodegen", "brew"])
        #expect(suggestion.notes.contains { $0.contains("does not run XcodeGen") })
        // No machines: a placeholder version, with a note.
        #expect(workflow.xcode == "27.2")
        #expect(suggestion.notes.contains { $0.contains("Xcode") })
    }

    @Test func xcodeGenSchemesFromTargetsWhenNoneDeclared() throws {
        var fixture = legilo
        fixture.files["project.yml"] = String(legiloProjectYML[..<legiloProjectYML.range(of: "schemes:")!.lowerBound])
        let suggestion = try fixture.detect()
        #expect(suggestion.workflows.workflows["release"]?.actions.map(\.scheme) == ["Legilo", "LegiloMobile"])
        #expect(suggestion.notes.contains { $0.contains("No shared schemes") })
    }

    @Test func plainProjectWithSharedSchemes() throws {
        let suggestion = try batFi.detect(machines: [machine("mini", xcodes: ["27.1"], online: false)])
        let workflow = try #require(suggestion.workflows.workflows["release"])
        #expect(workflow.project == "BatFi.xcodeproj")
        #expect(workflow.tools == [])
        #expect(workflow.teamID == "ABCDE12345")
        #expect(workflow.xcode == "27")
        #expect(workflow.actions == [
            WorkflowAction(scheme: "BatFi", platform: .macOS, export: .appStoreConnect),
            WorkflowAction(scheme: "Companion", platform: .iOS, export: .appStoreConnect),
        ])
        #expect(suggestion.schemes == [
            DetectedScheme(name: "BatFi", platform: .macOS, isApplication: true, hasTests: true),
            DetectedScheme(name: "BatFiKit", platform: .macOS, isApplication: false),
            DetectedScheme(name: "BatFiTests", platform: .macOS, isApplication: false),
            DetectedScheme(name: "Companion", platform: .iOS, isApplication: true),
        ])
        #expect(suggestion.icon == DetectedIcon(path: "BatFi/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png", kind: .appiconset))
        #expect(try WorkflowFileParser.parse(suggestion.yaml) == suggestion.workflows)
    }

    @Test func workspaceInSubdirectory() throws {
        let fixture = Fixture(
            files: [
                "iOS/Winyl.xcodeproj/project.pbxproj": pbxproj(targets: [("T1", "Winyl", "application", "iphoneos", nil)]),
            ],
            others: [
                "iOS/Winyl.xcworkspace/contents.xcworkspacedata",
                "iOS/Winyl.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
                "iOS/Winyl.xcodeproj/xcshareddata/xcschemes/Winyl.xcscheme",
                "iOS/Pods/Pods.xcodeproj/project.pbxproj",
                "iOS/Pods/Pods.xcodeproj/xcshareddata/xcschemes/Alamofire.xcscheme",
                "iOS/Podfile",
            ])
        let suggestion = try fixture.detect()
        let workflow = try #require(suggestion.workflows.workflows["release"])
        #expect(workflow.workspace == "iOS/Winyl.xcworkspace")
        #expect(workflow.project == nil)
        #expect(workflow.teamID == nil)
        #expect(workflow.actions == [WorkflowAction(scheme: "Winyl", platform: .iOS, export: .appStoreConnect)])
        #expect(suggestion.schemes.map(\.name) == ["Winyl"])
        #expect(try WorkflowFileParser.parse(suggestion.yaml) == suggestion.workflows)
    }

    @Test func podsAreIgnored() throws {
        let fixture = Fixture(
            files: [
                "App.xcodeproj/project.pbxproj": pbxproj(targets: [("T1", "App", "application", "iphoneos", "TEAM123456")]),
                "Pods/Pods.xcodeproj/project.pbxproj": pbxproj(targets: [("T2", "Pods-App", "framework", "iphoneos", nil)]),
            ],
            others: [
                "Pods/Pods.xcodeproj/xcshareddata/xcschemes/Pods-App.xcscheme",
                "Carthage/Checkouts/Lib/Lib.xcodeproj/xcshareddata/xcschemes/Lib.xcscheme",
                "App/AppDelegate.swift",
            ])
        let suggestion = try fixture.detect()
        let workflow = try #require(suggestion.workflows.workflows["release"])
        #expect(workflow.project == "App.xcodeproj")
        #expect(workflow.actions == [WorkflowAction(scheme: "App", platform: .iOS, export: .appStoreConnect)])
        #expect(suggestion.schemes.map(\.name) == ["App"])
        #expect(suggestion.notes.contains { $0.contains("No shared schemes") })
    }

    @Test func iconComposerIcon() throws {
        let fixture = Fixture(
            files: [
                "App.xcodeproj/project.pbxproj": pbxproj(targets: [("T1", "App", "application", "iphoneos", nil)]),
            ],
            others: [
                "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme",
                "App/AppIcon.icon/icon.json",
                "App/AppIcon.icon/Assets/Foreground.png",
                "App/Assets.xcassets/Contents.json",
                "App/Assets.xcassets/AccentColor.colorset/Contents.json",
            ])
        let suggestion = try fixture.detect()
        #expect(suggestion.icon == DetectedIcon(path: "App/AppIcon.icon", kind: .iconcomposer))
    }

    @Test func nothingFound() {
        for fixture in [
            Fixture(files: ["README.md": "hi"], others: ["Package.swift", "Sources/App/main.swift"]),
            Fixture(files: [:], others: ["Pods/Pods.xcodeproj/project.pbxproj"]),
        ] {
            #expect(throws: WorkflowDetectionError.noProjectFound) { try fixture.detect() }
        }
    }

    @Test func yamlQuotesWhatNeedsIt() throws {
        let file = WorkflowFile(version: 1, workflows: [
            "release": Workflow(
                project: "My App/My App.xcodeproj", xcode: "27.10", teamID: "1ABCDE2345", tools: ["yes"],
                actions: [
                    WorkflowAction(scheme: "App: Release", platform: .iOS, export: .appStoreConnect),
                    WorkflowAction(scheme: "true", platform: .macOS, export: .appStoreConnect),
                    WorkflowAction(scheme: "Line\u{2028}\"x\" \\", platform: .tvOS, export: .developerID),
                ]),
        ])
        #expect(try WorkflowFileParser.parse(WorkflowYAMLWriter.yaml(file)) == file)
    }

    // MARK: Inspection

    private static let legiloLike = Fixture(
        files: [
            "project.yml": """
                name: Legilo
                options:
                  bundleIdPrefix: software.micropixels
                settings:
                  base:
                    DEVELOPMENT_TEAM: YL78V8PY6H
                targets:
                  Legilo:
                    type: application
                    platform: macOS
                    sources:
                      - path: App/LegiloUI
                    settings:
                      base:
                        PRODUCT_BUNDLE_IDENTIFIER: software.micropixels.legilo
                        ASSETCATALOG_COMPILER_APPICON_NAME: legilo
                  LegiloShare:
                    type: app-extension
                    platform: macOS
                    sources: [App/LegiloShare]
                    settings:
                      base:
                        PRODUCT_BUNDLE_IDENTIFIER: software.micropixels.legilo.share
                  LegiloCapture:
                    type: application
                    platform: macOS
                    sources: [App/LegiloCapture]
                  LegiloMobile:
                    type: application
                    platform: iOS
                    sources: [App/LegiloMobile]
                    settings:
                      base:
                        BASE_ID: software.micropixels.legilo
                        PRODUCT_BUNDLE_IDENTIFIER: $(BASE_ID)
                        ASSETCATALOG_COMPILER_APPICON_NAME: legilo
                  LegiloTests:
                    type: bundle.unit-test
                    platform: macOS
                    sources: [LegiloTests]
                schemes:
                  Legilo:
                    build:
                      targets:
                        Legilo: all
                        LegiloShare: all
                  LegiloMobile:
                    build:
                      targets:
                        LegiloMobile: all
                """,
            "ci_scripts/ci_post_clone.sh": "xcodegen generate\n",
        ],
        others: [
            "App/LegiloUI/legilo.icon/icon.json", "App/LegiloUI/legilo.icon/Assets/1 - Layer.png",
            "App/LegiloUI/LegiloApp.swift", "App/LegiloCapture/main.swift", "App/LegiloMobile/App.swift",
        ])

    @Test func inspectGroupsTargetsSharingABundleID() throws {
        let inspection = try WorkflowDetector.inspect(tree: Self.legiloLike.tree, files: Self.legiloLike.fetchAll(), commit: "c0ffee")
        #expect(inspection.commit == "c0ffee")
        #expect(inspection.projects == ["Legilo.xcodeproj"])
        // LegiloCapture is an app no scheme builds (a helper the Mac app embeds), so it is left out.
        #expect(inspection.apps == [
            DetectedApp(
                name: "Legilo", bundleIDs: ["software.micropixels.legilo"], platforms: [.macOS, .iOS],
                schemes: [
                    DetectedScheme(name: "Legilo", platform: .macOS, isApplication: true, hasTests: true),
                    DetectedScheme(name: "LegiloMobile", platform: .iOS, isApplication: true),
                ],
                icon: DetectedIcon(path: "App/LegiloUI/legilo.icon", kind: .iconcomposer)),
        ])
    }

    @Test func inspectReadsBundleIDsFromThePBXProj() throws {
        let inspection = try WorkflowDetector.inspect(tree: batFi.tree, files: batFi.fetchAll(), commit: "c")
        #expect(inspection.projects == ["BatFi.xcodeproj"])
        #expect(inspection.apps.map(\.name) == ["BatFi", "CompanionApp"])
        #expect(inspection.apps[0].bundleIDs == ["software.micropixels.BatFi"])
        #expect(inspection.apps[0].platforms == [.macOS])
        #expect(inspection.apps[0].schemes.map(\.name) == ["BatFi"])
        #expect(inspection.apps[0].icon?.kind == .appiconset)
        // $(BASE_ID) is set nowhere in the file (an xcconfig, say): that bundle ID is skipped.
        #expect(inspection.apps[1].bundleIDs == [])
        #expect(inspection.apps[1].schemes.map(\.name) == ["Companion"])
        #expect(inspection.apps[1].platforms == [.iOS])
    }

    @Test func inspectReadsBundleIDsFromXcconfigFiles() throws {
        let fixture = Fixture(
            files: [
                "BatFi.xcodeproj/project.pbxproj": pbxproj(
                    targets: [("T1", "BatFi", "application", "macosx", nil)],
                    bundleIDs: ["BatFi": "$(APP_BUNDLE_IDENTIFIER)"], configFiles: ["BatFi": "AppConfig.xcconfig"]),
                "App/AppConfig.xcconfig": """
                    // AppConfig.xcconfig
                    #include "../Supporting Files/Config.xcconfig"
                    DISPLAY_NAME = BatFi
                    PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_IDENTIFIER)
                    """,
                "Supporting Files/Config.xcconfig": """
                    APP_BUNDLE_IDENTIFIER = software.micropixels.BatFi // the app
                    APP_BUNDLE_IDENTIFIER[sdk=iphoneos*] = nope
                    HELPER_TOOL_BUNDLE_IDENTIFIER = $(APP_BUNDLE_IDENTIFIER).Helper
                    """,
            ],
            others: ["BatFi.xcodeproj/xcshareddata/xcschemes/BatFi.xcscheme", "Other/AppConfig.xcconfig.bak"])
        var requests = 0
        _ = try fixture.detect(requests: &requests)
        let inspection = try WorkflowDetector.inspect(tree: fixture.tree, files: fixture.fetchAll(), commit: "c")
        #expect(inspection.apps.map(\.bundleIDs) == [["software.micropixels.BatFi"]])
        #expect(requests <= WorkflowDetector.maxFileFetches)
    }

    @Test func xcodeGenBundleIDFromItsConfigFile() throws {
        let fixture = Fixture(
            files: [
                "iOS/project.yml": """
                    name: Winyl
                    targets:
                      Winyl:
                        type: application
                        platform: iOS
                        sources:
                          - path: Winyl
                            type: syncedFolder
                        configFiles:
                          Debug: Winyl/Configuration/Debug.xcconfig
                          Release: Winyl/Configuration/Release.xcconfig
                        settings:
                          base:
                            PRODUCT_BUNDLE_IDENTIFIER: $PRODUCT_BUNDLE_IDENTIFIER
                    """,
                "iOS/Winyl/Configuration/Release.xcconfig": "#include \"Shared.xcconfig\"\nNATIVE_APPLE_SIGN_IN = YES\n",
                "iOS/Winyl/Configuration/Shared.xcconfig": "PRODUCT_BUNDLE_IDENTIFIER = software.micropixels.Winyl\nURL = https:/$()/winyl.app\n",
            ],
            others: ["iOS/Winyl/Configuration/Debug.xcconfig", "iOS/Winyl/WinylApp.swift"])
        let inspection = try WorkflowDetector.inspect(tree: fixture.tree, files: fixture.fetchAll(), commit: "c")
        #expect(inspection.apps.map(\.bundleIDs) == [["software.micropixels.Winyl"]])
    }

    @Test func layersResolveSelfReferences() {
        let all = WorkflowDetector.layered([
            ["PRODUCT_BUNDLE_IDENTIFIER": "com.acme.app", "FLAGS": "-a"],
            ["PRODUCT_BUNDLE_IDENTIFIER": "$PRODUCT_BUNDLE_IDENTIFIER", "FLAGS": "$(inherited) -b"],
        ])
        #expect(all == ["PRODUCT_BUNDLE_IDENTIFIER": "com.acme.app", "FLAGS": "-a -b"])
    }

    @Test func suggestionForOneAppOfSeveral() throws {
        let fixture = Fixture(
            files: [
                "BatFi.xcodeproj/project.pbxproj": pbxproj(
                    targets: [
                        ("T1", "BatFi", "application", "macosx", nil), ("T2", "Installer", "application", "macosx", nil),
                    ],
                    bundleIDs: ["BatFi": "software.micropixels.BatFi", "Installer": "software.micropixels.BatFi.Installer"]),
            ],
            others: [
                "BatFi.xcodeproj/xcshareddata/xcschemes/BatFi.xcscheme",
                "BatFi.xcodeproj/xcshareddata/xcschemes/Installer.xcscheme",
            ])
        let files = fixture.fetchAll()
        let all = try WorkflowDetector.suggest(tree: fixture.tree, files: files, machines: [])
        #expect(all.workflows.workflows["release"]?.actions.map(\.scheme) == ["BatFi", "Installer"])
        let one = try WorkflowDetector.suggest(
            tree: fixture.tree, files: files, machines: [], bundleIDs: ["software.micropixels.BatFi.Installer"])
        #expect(one.workflows.workflows["release"]?.actions.map(\.scheme) == ["Installer"])
        #expect(one.schemes.map(\.name) == ["BatFi", "Installer"])
        // A bundle ID no app has changes nothing.
        let none = try WorkflowDetector.suggest(tree: fixture.tree, files: files, machines: [], bundleIDs: ["com.other"])
        #expect(none.workflows == all.workflows)
    }

    @Test func reportsTheRepositorysOwnWorkflowFile() throws {
        var fixture = batFi
        #expect(try fixture.detect().hasWorkflowFile == false)
        fixture.others.append(".hangar.yml")
        #expect(try fixture.detect().hasWorkflowFile == true)
        #expect(try WorkflowDetector.inspect(tree: fixture.tree, files: fixture.fetchAll()).hasWorkflowFile == true)
    }

    @Test func notesFilesItCouldNotRead() throws {
        var fixture = legilo
        fixture.files["project.yml"] = "name: [unclosed"
        #expect(try fixture.detect().notes.contains { $0.contains("project.yml could not be read") })
        fixture.files["project.yml"] = "include: [base.yml, {path: targets.yml}]\n" + legiloProjectYML
        #expect(try fixture.detect().notes.contains { $0.contains("includes base.yml, targets.yml") })
        var plain = batFi
        plain.files["BatFi.xcodeproj/project.pbxproj"] = "{ not a plist"
        #expect(try plain.detect().notes.contains { $0.contains("project.pbxproj could not be parsed") })
    }

    @Test func skipsHugeFiles() throws {
        var tree = batFi.tree
        tree.sizes = [
            "BatFi.xcodeproj/project.pbxproj": 9 * 1_048_576,
            "BatFi/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png": 6 * 1_048_576,
        ]
        #expect(!WorkflowDetector.filesToFetch(tree: tree, files: [:]).contains("BatFi.xcodeproj/project.pbxproj"))
        let suggestion = try WorkflowDetector.suggest(
            tree: tree, files: ["BatFi/Assets.xcassets/AppIcon.appiconset/Contents.json": macIconSet], machines: [])
        #expect(suggestion.notes.contains { $0.contains("project.pbxproj is 9 MB, too big") })
        #expect(suggestion.notes.contains { $0.contains("too big to show") })
    }

    @Test func notesSeveralAppsWithoutABundleID() throws {
        let fixture = Fixture(
            files: [
                "A.xcodeproj/project.pbxproj": pbxproj(
                    targets: [("T1", "A", "application", "macosx", nil), ("T2", "B", "application", "macosx", nil)],
                    bundleIDs: ["A": "com.a", "B": "com.b"]),
            ],
            others: ["A.xcodeproj/xcshareddata/xcschemes/A.xcscheme", "A.xcodeproj/xcshareddata/xcschemes/B.xcscheme"])
        let files = fixture.fetchAll()
        #expect(try WorkflowDetector.suggest(tree: fixture.tree, files: files, machines: []).notes.contains { $0.contains("builds 2 apps") })
        #expect(try !WorkflowDetector.suggest(tree: fixture.tree, files: files, machines: [], bundleIDs: ["com.a"]).notes.contains { $0.contains("builds 2 apps") })
        #expect(try WorkflowDetector.suggest(tree: fixture.tree, files: files, machines: [], bundleIDs: ["com.zzz"]).notes.contains { $0.contains("builds 2 apps") })
    }

    @Test func suggestionListsProjectsTestPlansAndWhatToTestFiles() throws {
        let fixture = Fixture(
            files: ["iOS/Winyl.xcodeproj/project.pbxproj": pbxproj(targets: [("T1", "Winyl", "application", "iphoneos", nil)])],
            others: [
                "iOS/Winyl.xcworkspace/contents.xcworkspacedata",
                "iOS/Winyl.xcodeproj/xcshareddata/xcschemes/Winyl.xcscheme",
                "iOS/Plans/Smoke.xctestplan", "iOS/Full.xctestplan", "Pods/Other/Pod.xctestplan",
                "iOS/TestFlight/WhatToTest.en-US.txt", "iOS/TestFlight/WhatToTest.pl.txt", "iOS/TestFlight/notes.txt",
                "TestFlight/WhatToTest.de.txt",
            ])
        let suggestion = try fixture.detect()
        #expect(suggestion.projects == ["iOS/Winyl.xcworkspace", "iOS/Winyl.xcodeproj"])
        #expect(suggestion.testPlans == ["Full", "Smoke"])
        #expect(suggestion.whatToTestFiles == ["iOS/TestFlight/WhatToTest.en-US.txt", "iOS/TestFlight/WhatToTest.pl.txt"])
    }

    @Test func schemesWithTestsFromSchemeFilesAndTestTargetNames() throws {
        let testable = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Scheme LastUpgradeVersion = "2700" version = "1.7">
               <BuildAction><BuildActionEntries><BuildActionEntry><BuildableReference BlueprintName = "Pad"></BuildableReference></BuildActionEntry></BuildActionEntries></BuildAction>
               <TestAction buildConfiguration = "Debug">
                  <Testables><TestableReference skipped = "NO"><BuildableReference BlueprintName = "PadChecks"></BuildableReference></TestableReference></Testables>
               </TestAction>
            </Scheme>
            """
        let fixture = Fixture(
            files: [
                "App.xcodeproj/project.pbxproj": pbxproj(targets: [
                    ("T1", "Phone", "application", "iphoneos", nil),
                    ("T2", "Pad", "application", "iphoneos", nil),
                    ("T3", "Watch", "application", "watchos", nil),
                    ("T4", "PhoneUITests", "bundle.ui-testing", "iphoneos", nil),
                    ("T5", "PadChecks", "bundle.unit-test", "iphoneos", nil),
                ]),
                "App.xcodeproj/xcshareddata/xcschemes/Tablet.xcscheme": testable,
            ],
            others: ["App.xcodeproj/xcshareddata/xcschemes/Phone.xcscheme", "App.xcodeproj/xcshareddata/xcschemes/Watch.xcscheme"])
        let suggestion = try fixture.detect()
        #expect(suggestion.schemes.map(\.name) == ["Phone", "Tablet", "Watch"])
        #expect(suggestion.schemes.map(\.hasTests) == [true, true, false])
    }

    @Test func inspectListsEveryProject() throws {
        let fixture = Fixture(
            files: ["iOS/Winyl.xcodeproj/project.pbxproj": pbxproj(targets: [("T1", "Winyl", "application", "iphoneos", nil)])],
            others: [
                "iOS/Winyl.xcworkspace/contents.xcworkspacedata",
                "iOS/Winyl.xcodeproj/xcshareddata/xcschemes/Winyl.xcscheme",
                "Examples/Demo/Demo.xcodeproj/project.pbxproj",
                "Pods/Pods.xcodeproj/project.pbxproj",
            ])
        let inspection = try WorkflowDetector.inspect(tree: fixture.tree, files: fixture.fetchAll(), commit: "c")
        #expect(inspection.projects == ["iOS/Winyl.xcworkspace", "Examples/Demo/Demo.xcodeproj", "iOS/Winyl.xcodeproj"])
    }

    @Test func matchesAppStoreConnectByBundleID() {
        let apps = [
            DetectedApp(name: "Helper", bundleIDs: ["com.acme.helper"], platforms: [.macOS], schemes: [], icon: nil),
            DetectedApp(name: "Legilo", bundleIDs: ["software.micropixels.legilo"], platforms: [.macOS, .iOS], schemes: [], icon: nil),
            DetectedApp(name: "NoID", bundleIDs: [], platforms: [.iOS], schemes: [], icon: nil),
        ]
        let asc = ASCAppSummary(id: "6450000000", name: "Legilo: Read Later", bundleID: "software.micropixels.legilo", registered: true)
        let matched = WorkflowDetector.matchAppStoreConnect(apps, ascApps: [asc])
        #expect(matched.map(\.name) == ["Legilo: Read Later", "Helper", "NoID"])
        #expect(matched[0].appStoreConnect == asc)
        #expect(matched[1].appStoreConnect == nil)
    }

    @Test(arguments: [
        ("software.micropixels.$(PRODUCT_NAME:rfc1034identifier)", ["PRODUCT_NAME": "Hourly Beep"], "software.micropixels.Hourly-Beep"),
        ("${BASE}.$(TARGET_NAME:lower)", ["BASE": "com.acme", "TARGET_NAME": "App"], "com.acme.app"),
        ("$(inherited)com.acme.x", [:], "com.acme.x"),
        ("$(BASE).x", ["BASE": "$(DEEPER)", "DEEPER": "com.acme"], "com.acme.x"),
        ("$(MISSING).x", [:], nil),
        ("$(BROKEN", [:], nil),
        ("$PRODUCT_NAME.x", ["PRODUCT_NAME": "App"], "App.x"),
        ("https:/$()/winyl.app", [:], "https://winyl.app"),
    ] as [(String, [String: String], String?)])
    func resolvesBuildSettingReferences(value: String, settings: [String: String], expected: String?) {
        #expect(WorkflowDetector.resolve(value, settings: settings) == expected)
    }
}

@Test func multiplatformSchemeIsOneBuildPerPlatform() throws {
    let fixture = Fixture(files: [
        "Velum.xcodeproj/project.pbxproj": pbxproj(
            targets: [("T1", "Velum", "application", "auto", nil)],
            supportedPlatforms: ["Velum": "iphoneos iphonesimulator macosx"]),
        "Velum.xcodeproj/xcshareddata/xcschemes/Velum.xcscheme": xcscheme(blueprint: "Velum"),
    ])
    let suggestion = try fixture.detect()
    let scheme = try #require(suggestion.schemes.first { $0.name == "Velum" })
    #expect(scheme.platforms == [.iOS, .macOS])
    #expect(scheme.platform == nil)
    #expect(scheme.isApplication)
    let actions = try #require(suggestion.workflows.workflows["release"]?.actions)
    #expect(actions == [
        WorkflowAction(scheme: "Velum", platform: .iOS, export: .appStoreConnect),
        WorkflowAction(scheme: "Velum", platform: .macOS, export: .appStoreConnect),
    ])
    #expect(suggestion.notes.contains { $0.contains("Scheme Velum builds for iOS and macOS") })
    let data = try JSONEncoder().encode(scheme)
    let decoded = try JSONDecoder().decode(DetectedScheme.self, from: data)
    #expect(decoded.platforms == [.iOS, .macOS])
}

extension Fixture {
    /// Every text file the detector asks for, fetched round by round.
    func fetchAll() -> [String: String] {
        var fetched: [String: String] = [:]
        var asked = Set<String>()
        for _ in 0..<WorkflowDetector.maxFetchRounds {
            let wanted = WorkflowDetector.filesToFetch(tree: tree, files: fetched).filter { !asked.contains($0) }
                .prefix(WorkflowDetector.maxFileFetches - asked.count)
            if wanted.isEmpty { break }
            for path in wanted {
                asked.insert(path)
                if let text = files[path] { fetched[path] = text }
            }
        }
        return fetched
    }
}
