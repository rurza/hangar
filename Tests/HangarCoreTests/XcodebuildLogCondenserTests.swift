import Foundation
import Testing
@testable import HangarCore

/// The samples are cut from a real `xcodebuild archive` of Legilo on a Hangar worker (long invocations shortened
/// where their length does not matter).
@Suite struct XcodebuildLogCondenserTests {
    static let repo = "/Users/adam/.hangar/worker/workspaces/legilo/repository"
    static let derived = "/Users/adam/.hangar/worker/workspaces/legilo/DerivedData"
    static let intermediates = derived + "/Build/Intermediates.noindex/ArchiveIntermediates/LegiloMobile/IntermediateBuildFilesPath"

    static func condense(_ text: String) -> [String] {
        XcodebuildLogCondenser.condense(text.components(separatedBy: "\n"))
    }

    @Test func swiftCompileListingEverySourceFileBecomesNothing() {
        // The line from the bug report: one SwiftCompile header naming ~600 files, about 70 KB.
        let files = (0..<600).map { "Source\($0).swift" }
        let header = "SwiftCompile normal arm64 Compiling\\ " + files.joined(separator: ",\\ ") + " "
            + files.map { "\(Self.repo)/Packages/LegiloKit/Sources/LegiloKit/\($0)" }.joined(separator: " ")
            + " (in target 'LegiloKit' from project 'Legilo')"
        #expect(header.utf8.count > 70_000)
        let log = """
            SwiftDriver LegiloKit normal arm64 com.apple.xcode.tools.swift.compiler (in target 'LegiloKit' from project 'Legilo')
                cd \(Self.repo)/Legilo.xcodeproj
                builtin-SwiftDriver -- /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -parse-as-library -module-name LegiloKit -O -whole-module-optimization @\(Self.intermediates)/Legilo.build/Release-iphoneos/LegiloKit-t.build/Objects-normal/arm64/LegiloKit.SwiftFileList

            \(header)

            SwiftCompile normal arm64 (in target 'LegiloKit' from project 'Legilo' at path '\(Self.repo)/Packages/LegiloKit/Package.swift')
                cd \(Self.repo)/Legilo.xcodeproj
                \("    ")

            SwiftDriverJobDiscovery normal arm64 Compiling Source0.swift, Source1.swift (in target 'LegiloKit' from project 'Legilo')

            SwiftDriver\\ Compilation\\ Requirements LegiloKit normal arm64 com.apple.xcode.tools.swift.compiler (in target 'LegiloKit' from project 'Legilo')
                cd \(Self.repo)/Legilo.xcodeproj
                builtin-Swift-Compilation-Requirements -- /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -module-name LegiloKit
            """
        #expect(Self.condense(log) == ["▸ Compile LegiloKit (arm64)"])
    }

    @Test func compilerDiagnosticsKeepTheirTaskAndSourceExcerpt() {
        let log = """
            SwiftCompile normal arm64 Compiling\\ AnalyticsClient+Live.swift \(Self.repo)/Packages/LegiloKit/Sources/LegiloKit/AnalyticsClient+Live.swift (in target 'LegiloKit' from project 'Legilo')
                cd \(Self.repo)/Packages/LegiloKit
                builtin-swiftTaskExecution -- /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -c -primary-file AnalyticsClient+Live.swift
            \(Self.repo)/Packages/LegiloKit/Sources/LegiloKit/AnalyticsClient+Live.swift:19:35: error: cannot find 'analyticsDSN' in scope
             17 |   static let liveValue = Self(
             18 |     send: { event in
             19 |       let url = URL(string: analyticsDSN)!
                |                             `- error: cannot find 'analyticsDSN' in scope
             20 |     }

            """
        #expect(Self.condense(log) == [
            "▸ Compile AnalyticsClient+Live.swift (LegiloKit)",
            "\(Self.repo)/Packages/LegiloKit/Sources/LegiloKit/AnalyticsClient+Live.swift:19:35: error: cannot find 'analyticsDSN' in scope",
            " 17 |   static let liveValue = Self(",
            " 18 |     send: { event in",
            " 19 |       let url = URL(string: analyticsDSN)!",
            "    |                             `- error: cannot find 'analyticsDSN' in scope",
            " 20 |     }",
        ])
    }

    @Test func warningsAfterTheBlankLineGetTheCompileTheyCameFrom() {
        // Real: the frontend's warnings follow the SwiftCompile block after its blank line.
        let log = """
            SwiftCompile normal arm64 (in target 'LegiloMobile' from project 'Legilo' at path '\(Self.repo)/Legilo.xcodeproj')
                cd \(Self.repo)


            \(Self.repo)/App/Onboarding/OnboardingSteps.swift:28:35: warning: Storing a closure in '@Entry var onboardingArrival' may invalidate dependents on every update
             26 |     /// the second a push takes and some; on the Mac, the sheet's own
             27 |     /// arrival — see `SheetArrival`.

            [#DeprecatedDeclaration]: <https://docs.swift.org/compiler/documentation/diagnostics/deprecated-declaration>
            """
        #expect(Self.condense(log) == [
            "▸ Compile Swift sources (LegiloMobile)",
            "\(Self.repo)/App/Onboarding/OnboardingSteps.swift:28:35: warning: Storing a closure in '@Entry var onboardingArrival' may invalidate dependents on every update",
            " 26 |     /// the second a push takes and some; on the Mac, the sheet's own",
            " 27 |     /// arrival — see `SheetArrival`.",
            "[#DeprecatedDeclaration]: <https://docs.swift.org/compiler/documentation/diagnostics/deprecated-declaration>",
        ])
    }

    @Test func metalWarningsAreKeptUnderTheirFile() {
        let metal = Self.derived + "/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
        let log = """
            CompileMetalFile \(metal)/rms_norm.metal (in target 'mlx-swift_Cmlx' from project 'mlx-swift')
                cd \(Self.derived)/SourcePackages/checkouts/mlx-swift
                /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v27.2.47.0.E058sm/Metal.xctoolchain/usr/bin/metal -c -target air64-apple-ios17.0 -o rms_norm.air
            In file included from \(metal)/rms_norm.metal:6:
            \(metal)/complex.h:157:54: warning: 'static_assert' with no message is a C++17 extension [-Wc++17-extensions]
            static_assert(sizeof(complex32_t) == 2 * sizeof(half));
                                                                 ^
            1 warning generated.

            CompileMetalFile \(metal)/rope.metal (in target 'mlx-swift_Cmlx' from project 'mlx-swift')
                cd \(Self.derived)/SourcePackages/checkouts/mlx-swift
                /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v27.2.47.0.E058sm/Metal.xctoolchain/usr/bin/metal -c -o rope.air
            \(metal)/utils.h:80:3: warning: inline variables are a C++17 extension [-Wc++17-extensions]

            CompileMetalFile \(metal)/quiet.metal (in target 'mlx-swift_Cmlx' from project 'mlx-swift')
                cd \(Self.derived)/SourcePackages/checkouts/mlx-swift
                /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v27.2.47.0.E058sm/Metal.xctoolchain/usr/bin/metal -c -o quiet.air
            """
        #expect(Self.condense(log) == [
            "▸ Compile Metal shaders (mlx-swift_Cmlx)",
            "In file included from \(metal)/rms_norm.metal:6:",
            "\(metal)/complex.h:157:54: warning: 'static_assert' with no message is a C++17 extension [-Wc++17-extensions]",
            "static_assert(sizeof(complex32_t) == 2 * sizeof(half));",
            "                                                     ^",
            "1 warning generated.",
            "▸ Compile rope.metal (mlx-swift_Cmlx)",
            "\(metal)/utils.h:80:3: warning: inline variables are a C++17 extension [-Wc++17-extensions]",
        ])
    }

    @Test func linkSignScriptAndDSYMReadLikeXcode() {
        let products = Self.intermediates + "/UninstalledProducts/iphoneos"
        let log = """
            CompileC \(Self.intermediates)/mlx-swift.build/Release-iphoneos/cLogSupport-t.build/Objects-normal/arm64/cLogSupport.o \(Self.derived)/SourcePackages/checkouts/mlx-swift/Source/cLogSupport/cLogSupport.c normal arm64 c com.apple.compilers.llvm.clang.1_0.compiler (in target 'cLogSupport' from project 'mlx-swift')
                cd \(Self.repo)/Legilo.xcodeproj
                \("    ")
                Using response file: \(Self.intermediates)/mlx-swift.build/Release-iphoneos/cLogSupport-t.build/Objects-normal/arm64/7187679823f38a2a940e0043cdf9d637-common-args.resp
                \("    ")
                /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -x c -target arm64-apple-ios17.0 -c cLogSupport.c

            CompileC \(Self.intermediates)/mlx-swift.build/Release-iphoneos/cLogSupport-t.build/Objects-normal/arm64/other.o \(Self.derived)/SourcePackages/checkouts/mlx-swift/Source/cLogSupport/other.c normal arm64 c com.apple.compilers.llvm.clang.1_0.compiler (in target 'cLogSupport' from project 'mlx-swift')
                cd \(Self.repo)/Legilo.xcodeproj
                /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -x c -c other.c

            Ld \(products)/cLogSupport.o normal (in target 'cLogSupport' from project 'mlx-swift')
                cd \(Self.derived)/SourcePackages/checkouts/mlx-swift
                /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -Xlinker -reproducible -target arm64-apple-ios17.0 -r

            Ld \(Self.intermediates)/Legilo.build/Release-iphoneos/LegiloMobile.build/Objects-normal/arm64/Binary/Legilo normal arm64 (in target 'LegiloMobile' from project 'Legilo')
                cd \(Self.repo)
                /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -Xlinker -reproducible -target arm64-apple-ios17.0

            PhaseScriptExecution Bundle\\ the\\ search-by-meaning\\ model \(Self.intermediates)/Legilo.build/Release-iphoneos/LegiloMobile.build/Script-15F5950C722EB0C84E0308BE.sh (in target 'LegiloMobile' from project 'Legilo')
                cd \(Self.repo)
                export ACTION\\=install
                export AD_HOC_CODE_SIGNING_ALLOWED\\=NO
                /bin/sh -c \(Self.intermediates)/Legilo.build/Release-iphoneos/LegiloMobile.build/Script-15F5950C722EB0C84E0308BE.sh
            note: a Release build carries no search-by-meaning model; it arrives as an asset pack.
                indented script output

            GenerateDSYMFile \(Self.derived)/Build/Intermediates.noindex/ArchiveIntermediates/LegiloMobile/BuildProductsPath/Release-iphoneos/Legilo.app.dSYM \(products)/Legilo.app/Legilo (in target 'LegiloMobile' from project 'Legilo')
                cd \(Self.repo)
                /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/dsymutil -o Legilo.app.dSYM

            CodeSign \(products)/Legilo.app (in target 'LegiloMobile' from project 'Legilo' at path '\(Self.repo)/Legilo.xcodeproj')
                cd \(Self.repo)
                \("    ")
                Signing Identity:     "Apple Development: Adam Rozynski (RF5D7S3VFD)"
                Provisioning Profile: "iOS Team Provisioning Profile: software.micropixels.legilo"
                                      (ab10242e-2833-45d2-a0cf-f55fd903e83f)
                \("    ")
                /usr/bin/codesign --force --sign 35DC72CA94039444EBCDBBB7D19AA039544ACE62 --entitlements Legilo.app.xcent \(products)/Legilo.app
            """
        #expect(Self.condense(log) == [
            "▸ Compile cLogSupport (arm64)",
            "▸ Link Legilo (arm64)",
            "▸ Run script 'Bundle the search-by-meaning model' (LegiloMobile)",
            "note: a Release build carries no search-by-meaning model; it arrives as an asset pack.",
            "    indented script output",
            "▸ Generate Legilo.app.dSYM",
            "▸ Sign Legilo.app",
            "  Signing Identity: \"Apple Development: Adam Rozynski (RF5D7S3VFD)\"",
            "  Provisioning Profile: \"iOS Team Provisioning Profile: software.micropixels.legilo\"",
        ])
    }

    @Test func housekeepingTasksAreDroppedUnlessTheyComplain() {
        let log = """
            WriteAuxiliaryFile \(Self.intermediates)/swift-syntax.build/Release/_SwiftSyntaxCShims-t.build/Objects-normal/x86_64/7187679823f38a2a940e0043cdf9d637-common-args.resp (in target '_SwiftSyntaxCShims' from project 'swift-syntax')
                cd \(Self.derived)/SourcePackages/checkouts/swift-syntax
                write-file \(Self.intermediates)/swift-syntax.build/Release/_SwiftSyntaxCShims-t.build/Objects-normal/x86_64/7187679823f38a2a940e0043cdf9d637-common-args.resp
            -fmodules -gmodules '-fmodules-cache-path=\(Self.derived)/ModuleCache.noindex' '-fmodule-name=_SwiftSyntaxCShims' -fpascal-strings -Os

            Copy \(Self.intermediates)/GeneratedModuleMaps-iphoneos/cLogSupport.modulemap \(Self.intermediates)/mlx-swift.build/cLogSupport.modulemap (in target 'cLogSupport' from project 'mlx-swift')
                cd \(Self.derived)/SourcePackages/checkouts/mlx-swift
                builtin-copy -exclude .DS_Store -exclude CVS -exclude .svn -exclude .git -exclude .hg -resolve-src-symlinks

            ComputeTargetDependencyGraph
            note: Building targets in dependency order
            note: Target dependency graph (109 targets)
                Target 'LegiloMobile' in project 'Legilo'
                    ➜ Explicit dependency on target 'LegiloMobileShare' in project 'Legilo'

            ExtractAppIntentsMetadata (in target 'LegiloKit' from project 'Legilo')
                cd \(Self.repo)
                /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor --toolchain-dir /Applications/Xcode.app
            2026-11-05 14:32:56.957 appintentsmetadataprocessor[51612:5536902] Starting App Intents metadata extraction
            2026-11-05 14:32:57.055 appintentsmetadataprocessor[51612:5536902] Extracted no relevant App Intents symbols, skipping writing output

            ExecuteExternalTool /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc --version

            ValidateEmbeddedBinary \(Self.derived)/Build/Intermediates.noindex/ArchiveIntermediates/LegiloMobile/BuildProductsPath/Release-iphoneos/Legilo.app/Extensions/LegiloMobileModelDownloader.appex (in target 'LegiloMobile' from project 'Legilo')
                cd \(Self.repo)
                /Applications/Xcode.app/Contents/Developer/usr/bin/embeddedBinaryValidationUtility LegiloMobileModelDownloader.appex
            warning: LegiloMobileModelDownloader.appex is an ExtensionKit extension and must be embedded in the parent app bundle's Extensions directory
            """
        #expect(Self.condense(log) == [
            "▸ Validate LegiloMobileModelDownloader.appex (LegiloMobile)",
            "warning: LegiloMobileModelDownloader.appex is an ExtensionKit extension and must be embedded in the parent app bundle's Extensions directory",
        ])
    }

    @Test func aQuietTaskStillShowsItsErrors() {
        let log = """
            WriteAuxiliaryFile \(Self.intermediates)/x.yaml (in target 'X' from project 'X')
                cd /tmp
                error: unable to write file '\(Self.intermediates)/x.yaml': No space left on device
                write-file \(Self.intermediates)/x.yaml
            """
        #expect(Self.condense(log) == [
            "▸ Write x.yaml (X)",
            "    error: unable to write file '\(Self.intermediates)/x.yaml': No space left on device",
            "    write-file \(Self.intermediates)/x.yaml",
        ])
    }

    @Test func failureSummaryAndXcodebuildsOwnLinesAreKept() {
        let failed = "SwiftCompile normal arm64 Compiling\\ AnalyticsClient+Live.swift \(Self.repo)/AnalyticsClient+Live.swift (in target 'LegiloKit' from project 'Legilo')"
        let log = """
            Command line invocation:
                /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild archive -project \(Self.repo)/Legilo.xcodeproj -scheme Legilo

            Resolve Package Graph

            Updating from https://github.com/groue/GRDB.swift

            Creating working copy of package ‘GRDB.swift’

            Checking out 7.11.1 of package ‘GRDB.swift’


            Resolved source packages:
              GRDB: https://github.com/groue/GRDB.swift @ 7.11.1

            resolved source packages: GRDB
            Build description signature: bd70de279883866e17b7a4c869259ec9
            error: Failed to parse artifactbundle at '\(Self.derived)/SourcePackages/artifacts/swift-tokenizers/TokenizersRust/TokenizersRust.artifactbundle': artifact bundle info.json not found
            note: Run script build phase 'Bundle the search-by-meaning model' will be run during every build because the option to run the script phase "Based on dependency analysis" is unchecked. (in target 'Legilo' from project 'Legilo')

            Result bundle written to path:
            \t/Users/adam/.hangar/worker/jobs/3792A17E-A3C0-4415-89C0-082733EF0908/result.xcresult

            ** ARCHIVE FAILED **


            The following build commands failed:
            \t\(failed)
            \tArchiving project Legilo with scheme Legilo
            (2 failures)
            """
        #expect(Self.condense(log) == [
            "▸ xcodebuild archive -project \(Self.repo)/Legilo.xcodeproj -scheme Legilo",
            "Resolve Package Graph",
            "Resolved source packages:",
            "  GRDB: https://github.com/groue/GRDB.swift @ 7.11.1",
            "error: Failed to parse artifactbundle at '\(Self.derived)/SourcePackages/artifacts/swift-tokenizers/TokenizersRust/TokenizersRust.artifactbundle': artifact bundle info.json not found",
            "note: Run script build phase 'Bundle the search-by-meaning model' will be run during every build because the option to run the script phase \"Based on dependency analysis\" is unchecked. (in target 'Legilo' from project 'Legilo')",
            "Result bundle written to path:",
            "\t/Users/adam/.hangar/worker/jobs/3792A17E-A3C0-4415-89C0-082733EF0908/result.xcresult",
            "** ARCHIVE FAILED **",
            "The following build commands failed:",
            "\tCompile AnalyticsClient+Live.swift (LegiloKit)",
            "\tArchiving project Legilo with scheme Legilo",
            "(2 failures)",
        ])
    }

    @Test func testResultsAreKept() {
        let log = """
            Test Suite 'All tests' started at 2026-11-05 14:40:01.123.
            Test Case '-[LegiloKitTests.ParserTests testEmpty]' passed (0.001 seconds).
            Test Case '-[LegiloKitTests.ParserTests testBroken]' failed (0.002 seconds).
            \(Self.repo)/Tests/ParserTests.swift:12: error: -[LegiloKitTests.ParserTests testBroken] : XCTAssertEqual failed: ("1") is not equal to ("2")
            ** TEST FAILED **
            """
        #expect(Self.condense(log) == log.components(separatedBy: "\n"))
    }

    @Test func condensingTwiceChangesNothing() {
        let log = """
            SwiftDriver LegiloKit normal arm64 com.apple.xcode.tools.swift.compiler (in target 'LegiloKit' from project 'Legilo')
                cd \(Self.repo)/Legilo.xcodeproj

            ValidateEmbeddedBinary /x/LegiloMobileModelDownloader.appex (in target 'LegiloMobile' from project 'Legilo')
                cd \(Self.repo)
            warning: embedded in the wrong place

            CodeSign /x/Legilo.app (in target 'LegiloMobile' from project 'Legilo')
                Signing Identity:     "Apple Development: Adam Rozynski (RF5D7S3VFD)"

            The following build commands failed:
            \tCodeSign /x/Legilo.app (in target 'LegiloMobile' from project 'Legilo')
            """
        let once = Self.condense(log)
        #expect(once.count == 7)
        #expect(XcodebuildLogCondenser.condense(once) == once)
    }

    @Test func entriesKeepTimeAndStepAndOnlyXcodebuildStepsAreCondensed() {
        let t = Date(timeIntervalSince1970: 1_000)
        let entries = [
            LogEntry(t: t, step: "post-clone", line: "Copy /a /b (in target 'X' from project 'X')"),
            LogEntry(t: t, step: "archive", line: "Copy /a /b (in target 'X' from project 'X')"),
            LogEntry(t: t, step: "archive", line: "    builtin-copy /a /b"),
            LogEntry(t: t, step: "archive", line: "warning: copied twice"),
            LogEntry(t: t, step: "test", line: "    an indented line outside any task"),
        ]
        #expect(XcodebuildLogCondenser.condense(entries) == [
            LogEntry(t: t, step: "post-clone", line: "Copy /a /b (in target 'X' from project 'X')"),
            LogEntry(t: t, step: "archive", line: "▸ Copy a (X)"),
            LogEntry(t: t, step: "archive", line: "warning: copied twice"),
            LogEntry(t: t, step: "test", line: "    an indented line outside any task"),
        ])
    }
}
