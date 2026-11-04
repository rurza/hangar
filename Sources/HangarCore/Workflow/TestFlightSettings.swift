public struct TestFlightSettings: PostActionSettings {
    public static let actionName = "testflight"

    public var waitForProcessing = true
    public var processingTimeoutMinutes = 60
    public var groups: [String] = []
    public var whatToTest = true
    public var submitForExternalReview = false

    public init() {}

    /// Unknown keys and wrongly typed values are rejected so typos surface at parse time.
    public init(settings: [String: JSONValue]) throws(WorkflowFileError) {
        func fail(_ reason: String) -> WorkflowFileError {
            .invalidPostActionSettings(name: Self.actionName, reason: reason)
        }
        let known: Set<String> = [
            "wait-for-processing", "processing-timeout-minutes", "groups", "what-to-test", "submit-for-external-review",
        ]
        if let unknown = settings.keys.filter({ !known.contains($0) }).sorted().first {
            throw fail("unknown setting '\(unknown)'")
        }
        func bool(_ key: String, _ current: Bool) throws(WorkflowFileError) -> Bool {
            guard let value = settings[key] else { return current }
            guard case .bool(let flag) = value else { throw fail("'\(key)' must be true or false, not a \(value.kind)") }
            return flag
        }
        waitForProcessing = try bool("wait-for-processing", waitForProcessing)
        whatToTest = try bool("what-to-test", whatToTest)
        submitForExternalReview = try bool("submit-for-external-review", submitForExternalReview)
        if let value = settings["processing-timeout-minutes"] {
            guard case .int(let minutes) = value, minutes > 0 else {
                throw fail("'processing-timeout-minutes' must be a positive integer")
            }
            processingTimeoutMinutes = minutes
        }
        if let value = settings["groups"] {
            guard case .array(let items) = value else { throw fail("'groups' must be a list of names, not a \(value.kind)") }
            groups = try items.map { item throws(WorkflowFileError) in
                guard case .string(let name) = item else { throw fail("'groups' must contain only strings") }
                return name
            }
        }
    }
}
