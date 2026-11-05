import Foundation
import Testing

/// What the build page's log shows (Web/assets/log-model.js), run in JXA.
@Suite(.timeLimit(.minutes(1))) struct LogModelTests {
    static func run(_ json: String, _ expression: String) throws -> String {
        try WorkflowYAMLRoundTripTests.runJXA(json: json, files: ["log-model.js"], expression)
    }

    static let repo = "/Users/adam/.hangar/worker/workspaces/legilo/repository"

    /// A condensed archive step as a current worker sends it (from a real Legilo build), with a checkout before it.
    static var entries: String {
        let lines: [(String, String)] = [
            ("checkout", "git -C \(repo) fetch --prune --tags --force origin"),
            ("archive", "▸ xcodebuild archive -project \(repo)/Legilo.xcodeproj -scheme LegiloMobile"),
            ("archive", "▸ Compile LegiloKit (arm64)"),
            ("archive", "▸ Compile Swift sources (LegiloMobile)"),
            ("archive", "\(repo)/App/Onboarding/OnboardingSteps.swift:28:35: warning: Storing a closure in '@Entry var onboardingArrival' may invalidate dependents"),
            ("archive", " 27 |     /// arrival — see `SheetArrival`."),
            ("archive", "    |                    `- warning: Storing a closure"),
            ("archive", "▸ Compile AnalyticsClient+Live.swift (LegiloKit)"),
            ("archive", "\(repo)/Packages/LegiloKit/Sources/LegiloKit/AnalyticsClient+Live.swift:19:35: error: cannot find 'analyticsDSN' in scope"),
            ("archive", "▸ Sign Legilo.app"),
            ("archive", "note: Run script build phase 'Bundle the search-by-meaning model' will be run during every build"),
            ("archive", "** ARCHIVE FAILED **"),
            ("archive", "error: xcodebuild exited with 65"),
            ("upload-artifacts", "uploading full-log.txt"),
        ]
        let objects = lines.map { step, line in
            ["t": "2026-11-05T13:32:03.736Z", "step": step, "line": line]
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: objects), as: UTF8.self)
    }

    @Test func linesAreClassified() throws {
        let output = try Self.run(Self.entries, """
            input.map((entry) => lineKind(entry.line)).join(',')
            """)
        #expect(output == "plain,task,task,task,warning,excerpt,excerpt,task,error,task,note,failed,error,plain")
        let more = try Self.run("[]", """
            ['** ARCHIVE SUCCEEDED **', 'clang: error: linker command failed', 'fatal error: too many errors emitted',
             "Test Case '-[A b]' failed (0.002 seconds).", '✗ LegiloTests/testSync(): XCTAssertEqual failed',
             '    error: indented repeats are not counted', 'warning: plain'].map(lineKind).join(',')
            """)
        #expect(more == "succeeded,error,error,error,error,plain,warning")
    }

    @Test func stepsGroupAndCountIssues() throws {
        let output = try Self.run(Self.entries, """
            (() => {
              const log = createLog();
              const changed = appendEntries(log, input.slice(0, 5));
              const later = appendEntries(log, input.slice(5));
              const totals = issueTotals(log);
              return [changed.join(' '), later.join(' '),
                log.steps.map((s) => `${s.name}:${s.lines.length}:${s.errors}e:${s.warnings}w`).join(' '),
                `${totals.errors} ${totals.warnings}`,
                issuePositions(log, 'error').map((p) => `${p.step}#${p.index}`).join(' '),
                countLabel(1, 'error') + ', ' + countLabel(2, 'warning')].join('\\n');
            })()
            """)
        #expect(output == """
            checkout archive
            archive upload-artifacts
            checkout:1:0e:0w archive:12:2e:1w upload-artifacts:1:0e:0w
            2 1
            archive#7 archive#11
            1 error, 2 warnings
            """)
    }

    @Test func failedStepOpensAndRunningStepWhileTheJobRuns() throws {
        let output = try Self.run(Self.entries, """
            (() => {
              const log = createLog();
              appendEntries(log, input);
              const steps = (archive) => [{ name: 'checkout', status: 'succeeded' }, { name: 'archive', status: archive },
                { name: 'upload-artifacts', status: 'succeeded' }];
              return [
                defaultOpenSteps(log, { status: 'failed', steps: steps('failed') }).join(' '),
                defaultOpenSteps(log, { status: 'running', steps: steps('running') }).join(' '),
                defaultOpenSteps(log, { status: 'succeeded', steps: steps('succeeded') }).join(' ') || '-',
                defaultOpenSteps(log, { status: 'failed', steps: steps('running') }).join(' '),
                defaultOpenSteps(log, { status: 'cancelled', steps: steps('running') }).join(' ') || '-',
                defaultOpenSteps(log, { status: 'failed', steps: [] }).join(' '),
              ].join('\\n');
            })()
            """)
        #expect(output == """
            archive
            archive
            -
            archive
            -
            archive
            """)
    }

    @Test func issuesFilterAndSearchKeepTheTaskTheyBelongTo() throws {
        let output = try Self.run(Self.entries, """
            (() => {
              const log = createLog();
              appendEntries(log, input);
              const archive = log.byName.archive;
              const show = (lines) => lines.map((line) => line.index).join(',');
              return [
                show(visibleLines(archive)),
                show(visibleLines(archive, { issuesOnly: true })),
                show(visibleLines(archive, { query: 'ANALYTICS' })),
                // Matches the shortened path as shown, too.
                show(visibleLines(archive, { query: 'App/Onboarding/OnboardingSteps.swift:28' })),
                show(visibleLines(archive, { issuesOnly: true, query: 'closure' })),
                show(visibleLines(archive, { query: 'Sign' })),
              ].join('\\n');
            })()
            """)
        #expect(output == """
            0,1,2,3,4,5,6,7,8,9,10,11
            2,3,6,7,11
            6,7
            2,3
            2,3
            8
            """)
    }

    @Test func pathsAreShortenedRelativeToTheRepositoryWithTheFullPathAsTitle() throws {
        let output = try Self.run("[]", """
            [
              '\(Self.repo)/Packages/LegiloKit/Sources/LegiloKit/AnalyticsClient+Live.swift:19:35: error: x',
              '/Users/adam/.hangar/worker/workspaces/legilo/DerivedData/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/utils.h:80:3: warning: y',
              'In /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.2.sdk/System/Library/Frameworks/UIKit.framework/Headers/UIDevice.h:61:52',
              '\\t/Users/adam/.hangar/worker/jobs/92D947B3-6069-465C-A5CD-DEC3DF86ED4E/result.xcresult',
              'cp /usr/local/bin/tool /etc/hosts',
              '-derivedDataPath /Users/adam/.hangar/worker/workspaces/legilo/DerivedData -resultBundlePath x',
              "at '/Users/adam/Library/Application Support/Hangar/worker/workspaces/legilo/DerivedData/SourcePackages/artifacts/x': not found",
              '▸ Compile LegiloKit (arm64)',
            ].map((text) => pathSegments(text).map((s) => s.title ? `<${s.text}|${s.title.length}>` : s.text).join('')).join('\\n')
            """)
        #expect(output == """
            <Packages/LegiloKit/Sources/LegiloKit/AnalyticsClient+Live.swift|119>:19:35: error: x
            <SourcePackages/mlx-swift/Source/Cmlx/mlx-generated/metal/utils.h|131>:80:3: warning: y
            In <iPhoneOS27.2.sdk/System/Library/Frameworks/UIKit.framework/Headers/UIDevice.h|163>:61:52
            \t<job/result.xcresult|84>
            cp /usr/local/bin/tool /etc/hosts
            -derivedDataPath <DerivedData|56> -resultBundlePath x
            at '<DerivedData/SourcePackages/artifacts/x|110>': not found
            ▸ Compile LegiloKit (arm64)
            """)
    }

    @Test func searchMatchesAreMarkedInsideShortenedPaths() throws {
        let output = try Self.run("[]", """
            lineSegments('\(Self.repo)/App/Live.swift:3: error: live data', 'LIVE')
              .map((s) => (s.mark ? '[' + s.text + ']' : s.text) + (s.title ? '^' : '')).join('|')
            """)
        #expect(output == "App/^|[Live]^|.swift^|:3: error: |[live]| data")
    }
}
