import Foundation

public struct App: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var slug: String
    public var name: String
    public var repoURL: String
    public var appStoreConnectAppID: String
    public var iconURL: String?
    public var createdAt: Date

    public init(
        id: UUID, slug: String, name: String, repoURL: String, appStoreConnectAppID: String,
        iconURL: String? = nil, createdAt: Date
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.repoURL = repoURL
        self.appStoreConnectAppID = appStoreConnectAppID
        self.iconURL = iconURL
        self.createdAt = createdAt
    }

    /// Lowercased name with every run of non-alphanumerics collapsed to one `-`, trimmed of leading/trailing dashes.
    public static func slug(for name: String) -> String {
        var slug = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if slug.last != "-" {
                slug.append("-")
            }
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
