import Foundation

/// Masks secret values in log lines before they leave the machine.
///
/// Candidates per secret: the whole value and each non-blank line of it, all
/// trimmed of surrounding whitespace and newlines (so a trailing `\n` or
/// `\r\n` never hides the bare value). Candidates shorter than 4 characters
/// are ignored so ordinary words are never masked.
///
/// Detected forms of each candidate:
/// - the raw text;
/// - percent-encoding with both the alphanumerics-only set and the RFC 3986
///   unreserved set (`-._~` kept), each in upper- and lower-case hex, and the
///   form-encoded variants where a space becomes `+`;
/// - standard and URL-safe (unpadded) base64 of the whole candidate;
/// - the stable middle of that base64 when the candidate is embedded at byte
///   offset 0, 1 or 2 of a larger encoded value (e.g. `user:secret` in a Basic
///   auth header). Leading characters that mix in preceding bytes and trailing
///   characters that mix in following bytes are dropped, and the remainder is
///   used only if it is at least 4 characters long.
///
/// Not detected: other encodings (hex, gzip, ...), base64 of only part of a
/// candidate, or a secret split across several log lines other than via its
/// own lines. Longer patterns are replaced first so a secret that contains
/// another is masked as a single token.
public struct SecretMasker: Sendable {
    public static let token = "[masked]"
    private static let minimumLength = 4
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private let patterns: [String]

    public init(secrets: [String]) {
        var candidates = Set<String>()
        for secret in secrets {
            var variants = [secret]
            variants += secret.split(whereSeparator: \.isNewline).map { String($0) }
            for variant in variants {
                let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= Self.minimumLength else { continue }
                candidates.insert(trimmed)
                Self.percentForms(of: trimmed, into: &candidates)
                Self.base64Forms(of: trimmed, into: &candidates)
            }
        }
        patterns = candidates
            .filter { $0.count >= Self.minimumLength }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    public func mask(_ line: String) -> String {
        patterns.reduce(line) { $0.replacingOccurrences(of: $1, with: Self.token) }
    }

    private static func percentForms(of text: String, into out: inout Set<String>) {
        for allowed in [CharacterSet.alphanumerics, unreserved] {
            guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else { continue }
            out.insert(encoded)
            out.insert(lowercasingHex(encoded))
            let form = encoded.replacingOccurrences(of: "%20", with: "+")
            out.insert(form)
            out.insert(lowercasingHex(form))
        }
    }

    /// Lowercases the two hex digits after every `%`.
    private static func lowercasingHex(_ encoded: String) -> String {
        var result = ""
        var pending = 0
        for ch in encoded {
            if pending > 0 {
                result += ch.lowercased()
                pending -= 1
            } else {
                result.append(ch)
                if ch == "%" { pending = 2 }
            }
        }
        return result
    }

    private static func base64Forms(of text: String, into out: inout Set<String>) {
        func add(_ standard: String) {
            guard standard.count >= minimumLength else { return }
            out.insert(standard)
            out.insert(standard.replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: ""))
        }
        let bytes = Array(text.utf8)
        add(Data(bytes).base64EncodedString())
        for offset in 0...2 {
            let encoded = Array(Data([UInt8](repeating: 0, count: offset) + bytes).base64EncodedString().utf8)
            // Characters holding filler bits come first; characters that would
            // also hold following bytes come last.
            let lower = (offset * 8 + 5) / 6
            let upper = (offset + bytes.count) * 8 / 6
            guard upper - lower >= minimumLength else { continue }
            add(String(decoding: encoded[lower..<upper], as: UTF8.self))
        }
    }
}
