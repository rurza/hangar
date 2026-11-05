/// A value that must never be printed: the `hangar` account's password, the CI keychain's. Its descriptions are
/// redacted.
public struct SensitiveText: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}
