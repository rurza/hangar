import Foundation
import HangarCore

public struct TestFailure: Codable, Equatable, Sendable {
    /// `Suite/test()` as the result bundle names it.
    public var name: String
    /// The test's first failure message.
    public var message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}

/// The totals and failing tests of a result bundle, from `xcresulttool get test-results summary` (Xcode 16 and later).
public struct TestSummary: Equatable, Sendable {
    public static let failureCap = 50
    static let messageCap = 2000

    public var passed = 0
    public var failed = 0
    public var skipped = 0
    public var expectedFailures = 0
    public var total = 0
    /// One entry per failing test, in report order, at most `failureCap`.
    public var failures: [TestFailure] = []

    /// Lenient: missing numbers count as 0 and failures without a name are dropped. Nil when `data` is not a JSON
    /// object.
    public static func parse(_ data: Data) -> TestSummary? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func count(_ key: String) -> Int { (root[key] as? NSNumber)?.intValue ?? 0 }
        var summary = TestSummary(
            passed: count("passedTests"), failed: count("failedTests"), skipped: count("skippedTests"),
            expectedFailures: count("expectedFailures"))
        summary.total = (root["totalTestCount"] as? NSNumber)?.intValue
            ?? summary.passed + summary.failed + summary.skipped + summary.expectedFailures
        var seen = Set<String>()
        for entry in root["testFailures"] as? [[String: Any]] ?? [] {
            guard summary.failures.count < failureCap else { break }
            guard let name = (entry["testIdentifierString"] ?? entry["testName"]) as? String, !name.isEmpty,
                seen.insert(name).inserted
            else { continue }
            let message = (entry["failureText"] as? String) ?? ""
            summary.failures.append(TestFailure(name: name, message: String(message.prefix(messageCap))))
        }
        return summary
    }

    /// "128 passed · 2 failed · 3 skipped".
    public var line: String { "\(passed) passed · \(failed) failed · \(skipped) skipped" }

    /// The job outputs: `test.passed`, `test.failed`, `test.skipped`, `test.total` and `test.failures`, a JSON array
    /// of `{name, message}`.
    public var outputs: [String: String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let failuresJSON = (try? encoder.encode(failures)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return [
            "test.passed": String(passed), "test.failed": String(failed), "test.skipped": String(skipped),
            "test.total": String(total), "test.failures": failuresJSON,
        ]
    }
}

public enum TestError: Error, Equatable, CustomStringConvertible {
    /// xcodebuild failed without failing tests to explain it (a build error, a simulator that would not boot).
    case xcodebuildFailed(exitCode: Int32)
    case testsFailed(count: Int, exitCode: Int32)

    public var description: String {
        switch self {
        case .xcodebuildFailed(let exitCode): "xcodebuild test exited with status \(exitCode)"
        case .testsFailed(let count, _): count == 1 ? "1 test failed" : "\(count) tests failed"
        }
    }
}

/// What `xcodebuild test` did: its exit code and, when the result bundle could be read, the summary.
public struct TestRun: Sendable {
    public var exitCode: Int32
    public var summary: TestSummary?

    /// Throws `testsFailed` when tests failed, else `xcodebuildFailed` for a non-zero exit.
    public func check() throws(TestError) {
        if let summary, summary.failed > 0 { throw .testsFailed(count: summary.failed, exitCode: exitCode == 0 ? 65 : exitCode) }
        if exitCode != 0 { throw .xcodebuildFailed(exitCode: exitCode) }
    }
}

/// Runs `xcodebuild test` for one test action and reads the result bundle's summary afterwards, pass or fail.
/// Packages are resolved first exactly as for an archive; the test run itself sees no secrets.
public struct TestStep: Sendable {
    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner) {
        self.runner = runner
    }

    public static func command(
        workflow: Workflow, action: WorkflowAction, repository: String, layout: WorkspaceLayout, developerDir: String,
        destination: TestDestination, key: ASCKeyArguments?, environment: [String: String]
    ) -> ProcessCommand {
        let container = workflow.project.map { ["-project", "\(repository)/\($0)"] }
            ?? workflow.workspace.map { ["-workspace", "\(repository)/\($0)"] } ?? []
        let arguments =
            ["test"] + container + ["-scheme", action.scheme, "-destination", destination.xcodebuildDestination]
            + (action.testPlan.map { ["-testPlan", $0] } ?? []) + [
                "-derivedDataPath", layout.derivedData,
                "-resultBundlePath", layout.resultBundle,
                "-allowProvisioningUpdates",
                "-skipMacroValidation", "-skipPackagePluginValidation",
                "-disableAutomaticPackageResolution",
            ] + (key?.xcodebuildArguments ?? [])
        var environment = environment
        environment["DEVELOPER_DIR"] = developerDir
        return ProcessCommand(executable: "/usr/bin/xcodebuild", arguments: arguments, environment: environment)
    }

    public static func summaryCommand(layout: WorkspaceLayout, developerDir: String, environment: [String: String]) -> ProcessCommand {
        var environment = environment
        environment["DEVELOPER_DIR"] = developerDir
        return ProcessCommand(
            executable: "/usr/bin/xcrun",
            arguments: ["xcresulttool", "get", "test-results", "summary", "--path", layout.resultBundle, "--compact"],
            environment: environment)
    }

    /// Throws only when packages cannot be resolved or a tool cannot be launched; test failures are in the result.
    public func run(
        workflow: Workflow, action: WorkflowAction, repository: String, layout: WorkspaceLayout, developerDir: String,
        destination: TestDestination, key: ASCKeyArguments?, environment: [String: String], gitHubToken: String?,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> TestRun {
        guard !action.scheme.isEmpty, !action.scheme.contains("/"), !action.scheme.contains("..") else {
            throw ArchiveError.invalidScheme(action.scheme)
        }
        // xcodebuild refuses to overwrite a result bundle.
        try SafeRemoval.removeItem(atPath: layout.resultBundle, within: layout.jobDirectory)
        try FileManager.default.createDirectory(atPath: layout.jobDirectory, withIntermediateDirectories: true)
        let resolve = ArchiveStep.resolveCommand(
            workflow: workflow, action: action, repository: repository, layout: layout, developerDir: developerDir,
            environment: environment, gitHubToken: gitHubToken)
        let resolved = try await runner.run(resolve, onLine: log)
        guard resolved.exitCode == 0 else { throw ArchiveError.packageResolutionFailed(exitCode: resolved.exitCode) }

        let command = Self.command(
            workflow: workflow, action: action, repository: repository, layout: layout, developerDir: developerDir,
            destination: destination, key: key, environment: environment)
        let outcome = try await runner.run(command, onLine: log)
        let summary = await readSummary(
            layout: layout, developerDir: developerDir, environment: environment, exitCode: outcome.exitCode, log: log)
        return TestRun(exitCode: outcome.exitCode, summary: summary)
    }

    /// Logs the totals and each failing test; nil (logged) when there is no readable result bundle, or when a failed
    /// run has no tests in it (the build failed first), so no "0 passed" totals stand in for a build error.
    private func readSummary(
        layout: WorkspaceLayout, developerDir: String, environment: [String: String], exitCode: Int32,
        log: @escaping @Sendable (String) -> Void
    ) async -> TestSummary? {
        guard FileManager.default.fileExists(atPath: layout.resultBundle) else {
            log("no result bundle; no test results to report")
            return nil
        }
        let command = Self.summaryCommand(layout: layout, developerDir: developerDir, environment: environment)
        guard let outcome = try? await runner.run(command, onLine: { _ in }), outcome.exitCode == 0,
            let summary = TestSummary.parse(Data(outcome.output.utf8))
        else {
            log("could not read the test results from the result bundle")
            return nil
        }
        if exitCode != 0, summary.total == 0, summary.failures.isEmpty {
            log("no tests ran")
            return nil
        }
        log("Tests: \(summary.line)" + (summary.expectedFailures > 0 ? " · \(summary.expectedFailures) expected failures" : ""))
        for failure in summary.failures {
            log("✗ \(failure.name): \(failure.message.split(separator: "\n").first.map(String.init) ?? "")")
        }
        if summary.failed > summary.failures.count {
            log("… and \(summary.failed - summary.failures.count) more failing tests")
        }
        return summary
    }
}
