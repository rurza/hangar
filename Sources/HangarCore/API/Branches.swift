/// `GET /apps/{id}/branches`: the repository's branches for the Deploy sheet, the default branch first.
public struct RepositoryBranches: Codable, Equatable, Sendable {
    /// The branch a deploy without a choice builds; nil when the host did not say.
    public var defaultBranch: String?
    /// Every branch name (at most 100), the default branch first, then in the host's order.
    public var branches: [String]

    public init(defaultBranch: String?, branches: [String]) {
        self.defaultBranch = defaultBranch
        self.branches = branches
    }

    /// The same branches with the default one moved to the front.
    public var defaultFirst: RepositoryBranches {
        guard let defaultBranch else { return self }
        return RepositoryBranches(defaultBranch: defaultBranch, branches: [defaultBranch] + branches.filter { $0 != defaultBranch })
    }
}
