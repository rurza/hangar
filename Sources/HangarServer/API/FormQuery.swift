import Foundation
import Hummingbird

/// A request's query read as a form encodes it (`application/x-www-form-urlencoded`, what the browser's
/// `URLSearchParams` sends): `+` is a space and `%2B` a plus. Hummingbird's `uri.queryParameters` percent-decodes
/// but keeps `+`, so a workflow named "UX Review Keep" arrived as "UX+Review+Keep". Every route reads its query here.
struct FormQuery: Sendable {
    private let pairs: [(name: String, value: String)]

    init(_ query: String?) {
        pairs = (query ?? "").split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (Self.decode(parts[0]), parts.count > 1 ? Self.decode(parts[1]) : "")
        }
    }

    /// The first value of `name`, nil when absent; "" for `name=` or a bare `name`.
    func get(_ name: String) -> String? {
        pairs.first { $0.name == name }?.value
    }

    /// `+` to a space, then percent escapes; text that is not valid percent-encoding is kept as sent.
    static func decode(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

extension Request {
    /// The query, decoded as a form: see `FormQuery`.
    var query: FormQuery { FormQuery(uri.query) }
}
