import Foundation

/// A test job's results, read back from the `test.*` outputs the worker reports (`TestSummary.outputs`):
/// `test.passed`, `test.failed`, `test.skipped`, `test.total` and `test.failures`, a JSON array of `{name, message}`.
public struct TestOutputs: Codable, Equatable, Sendable {
    public struct Failure: Codable, Equatable, Sendable {
        public var name: String
        public var message: String

        public init(name: String, message: String) {
            self.name = name
            self.message = message
        }
    }

    public var passed: Int?
    public var failed: Int?
    public var skipped: Int?
    public var total: Int?
    public var failures: [Failure]?

    /// Nil when the job reported no `test.*` output.
    public init?(_ outputs: [String: String]) {
        guard outputs.keys.contains(where: { $0.hasPrefix("test.") }) else { return nil }
        passed = outputs["test.passed"].flatMap(Int.init)
        failed = outputs["test.failed"].flatMap(Int.init)
        skipped = outputs["test.skipped"].flatMap(Int.init)
        total = outputs["test.total"].flatMap(Int.init)
        failures = outputs["test.failures"].flatMap { try? JSONDecoder().decode([Failure].self, from: Data($0.utf8)) }
    }
}
