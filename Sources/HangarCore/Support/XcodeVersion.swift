public enum XcodeVersion {
    /// Component-wise prefix match: "27.2" matches "27.2" and "27.2.1", not "27.20".
    public static func matches(requested: String, installed: String) -> Bool {
        let wanted = requested.split(separator: ".", omittingEmptySubsequences: false)
        let have = installed.split(separator: ".", omittingEmptySubsequences: false)
        guard !wanted.isEmpty, wanted.count <= have.count else { return false }
        return zip(wanted, have).allSatisfy { $0 == $1 }
    }

    /// The highest installed version matching the request.
    public static func best(_ installed: [InstalledXcode], requested: String) -> InstalledXcode? {
        installed
            .filter { matches(requested: requested, installed: $0.version) }
            .max { components($0.version).lexicographicallyPrecedes(components($1.version)) }
    }

    /// "27.2.1" → [27, 2, 1], for ordering versions.
    public static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
