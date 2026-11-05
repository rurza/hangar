import Foundation

/// Names to match: every name (`any`), or a list of patterns (see `RefPattern`).
public enum RefPatterns: Equatable, Sendable, Codable {
    case any
    case patterns([String])

    /// Whether `name` matches: always for `any`, else when one of the patterns does.
    public func matches(_ name: String) -> Bool {
        switch self {
        case .any: true
        case .patterns(let patterns): patterns.contains { RefPattern.matches($0, name) }
        }
    }

    /// The patterns that are exact names (no `*`), in order; none for `any`.
    public var exactNames: [String] {
        guard case .patterns(let patterns) = self else { return [] }
        return patterns.filter { !$0.contains("*") }
    }

    /// JSON: the string `"any"` or an array of patterns.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard text == "any" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected \"any\" or a list of patterns")
            }
            self = .any
        } else {
            self = .patterns(try container.decode([String].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .any: try container.encode("any")
        case .patterns(let patterns): try container.encode(patterns)
        }
    }
}

/// Pattern matching for branch, tag and file names, shared by the editor's checks and the build trigger:
///
/// - A pattern without `*` matches exactly that name (case-sensitive).
/// - `*` matches any run of characters within one path component (not `/`): `release/*` matches `release/2.0` but
///   not `release/2.0/hotfix`; `v*` matches `v1.2`.
/// - `**` matches any run of characters, `/` included: `App/**` matches every file under `App/`, `**` matches all.
/// - The whole name must match; nothing else is special.
public enum RefPattern {
    public static func matches(_ pattern: String, _ name: String) -> Bool {
        matches(Array(pattern), 0, Array(name), 0)
    }

    private static func matches(_ pattern: [Character], _ p: Int, _ name: [Character], _ n: Int) -> Bool {
        if p == pattern.count { return n == name.count }
        if pattern[p] == "*" {
            let deep = p + 1 < pattern.count && pattern[p + 1] == "*"
            let rest = p + (deep ? 2 : 1)
            var index = n
            while true {
                if matches(pattern, rest, name, index) { return true }
                guard index < name.count, deep || name[index] != "/" else { return false }
                index += 1
            }
        }
        guard n < name.count, pattern[p] == name[n] else { return false }
        return matches(pattern, p + 1, name, n + 1)
    }
}

/// How a workflow starts (`start:` in the file). Only Xcode Cloud's manual start exists: a build is started from
/// Hangar, the CLI or a skill, from one of `manual.branches`. Without `start` that is any branch.
public struct WorkflowStart: Codable, Equatable, Sendable {
    public var manual: ManualStart

    public init(manual: ManualStart) {
        self.manual = manual
    }

    public init(branches: RefPatterns) {
        self.manual = ManualStart(branches: branches)
    }
}

public struct ManualStart: Codable, Equatable, Sendable {
    /// The branches a manual build may start from.
    public var branches: RefPatterns

    public init(branches: RefPatterns) {
        self.branches = branches
    }
}

extension Workflow {
    /// The branches a manual build may start from: `any` without `start`.
    public var sourceBranches: RefPatterns { start?.manual.branches ?? .any }

    /// The branch Deploy suggests: the first exact name of `sourceBranches`; nil for `any` or only globs (Deploy
    /// then suggests the repository's default branch).
    public var suggestedBranch: String? { sourceBranches.exactNames.first }
}
