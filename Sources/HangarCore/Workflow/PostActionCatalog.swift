public protocol PostActionSettings: Codable, Sendable {
    static var actionName: String { get }
    init(settings: [String: JSONValue]) throws(WorkflowFileError)
}

public enum PostActionCatalog {
    /// Phase 2 adds `script` by appending one entry.
    public static let all: [any PostActionSettings.Type] = [TestFlightSettings.self]

    public static func validate(_ spec: PostActionSpec, workflow: String) throws(WorkflowFileError) {
        guard let type = all.first(where: { $0.actionName == spec.name }) else {
            throw .unknownPostAction(name: spec.name, workflow: workflow)
        }
        do {
            _ = try type.init(settings: spec.settings)
        } catch {
            if case .invalidPostActionSettings = error { throw error }
            throw .invalidPostActionSettings(name: spec.name, reason: error.description)
        }
    }
}
