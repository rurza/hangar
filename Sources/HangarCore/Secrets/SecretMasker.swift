import Foundation

/// Masks secret values in log lines before they leave the machine.
///
/// For every secret the masker looks for the raw value, each line of a
/// multi-line value (trailing `\r` trimmed, blank lines skipped), the
/// percent-encoded form and the base64 of the UTF-8 bytes. Candidates shorter
/// than 4 characters are ignored so ordinary words are never masked. Longer
/// patterns are replaced first so a secret that contains another is masked as
/// a single token.
///
/// Limitation: only the base64 of a whole value (or whole line) is detected;
/// base64 of a substring of a secret is not.
public struct SecretMasker: Sendable {
    public static let token = "[masked]"
    private static let minimumLength = 4

    private let patterns: [String]

    public init(secrets: [String]) {
        var candidates = Set<String>()
        for secret in secrets {
            var variants = [secret]
            let lines = secret.split(whereSeparator: \.isNewline).map { String($0) }
            if lines.count > 1 { variants += lines }
            for variant in variants {
                let trimmed = variant.hasSuffix("\r") ? String(variant.dropLast()) : variant
                guard trimmed.count >= Self.minimumLength else { continue }
                candidates.insert(trimmed)
                if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                    candidates.insert(encoded)
                }
                candidates.insert(Data(trimmed.utf8).base64EncodedString())
            }
        }
        patterns = candidates
            .filter { $0.count >= Self.minimumLength }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    public func mask(_ line: String) -> String {
        patterns.reduce(line) { $0.replacingOccurrences(of: $1, with: Self.token) }
    }
}
