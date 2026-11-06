/// A value that must never be printed: a VM guest's password, a job keychain's. Its descriptions are
/// redacted.
public struct SensitiveText: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}
