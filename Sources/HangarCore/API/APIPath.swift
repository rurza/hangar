import Foundation

public enum APIPath {
    /// One path segment: anything but unreserved characters is percent-encoded, so a name cannot add segments.
    public static func segment(_ name: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    /// The artifact a job uploads with every line of its log as xcodebuild printed it.
    public static let fullLogArtifact = "full-log.txt"
}
