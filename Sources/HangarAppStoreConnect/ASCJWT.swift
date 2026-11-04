import CryptoKit
import Foundation

public enum ASCJWT {
    /// `iat` is set this far in the past, so a server clock slightly behind ours does not reject the token as issued
    /// in the future.
    public static let backdate: TimeInterval = 60

    /// The `exp` of a token issued at `now`: `iat` (`now` minus `backdate`) plus `lifetime`.
    public static func expiry(now: Date, lifetime: TimeInterval) -> Date {
        Date(timeIntervalSince1970: TimeInterval(issuedAt(now) + Int(lifetime)))
    }

    private static func issuedAt(_ now: Date) -> Int { Int(now.timeIntervalSince1970 - backdate) }

    /// ES256 token for the App Store Connect API (signature in raw r||s form, base64url without padding). Claims are
    /// `iss` for a team key or `sub: "user"` for an individual key, plus `iat`, `exp` and `aud`.
    /// `iat` is `now` minus `backdate`; `exp` is `iat` plus `lifetime`.
    public static func token(_ c: ASCCredentials, now: Date, lifetime: TimeInterval = 1200) throws -> String {
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: c.privateKeyPEM)
        } catch {
            throw ASCError.invalidPrivateKey
        }
        let issuedAt = issuedAt(now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(["alg": "ES256", "kid": c.keyID, "typ": "JWT"])
        // A team key names its issuer; an individual key has none and says `sub: user` instead.
        struct Claims: Encodable {
            var iss: String?
            var sub: String?
            var iat: Int
            var exp: Int
            var aud: String
        }
        let claims = try encoder.encode(
            Claims(
                iss: c.issuerID, sub: c.issuerID == nil ? "user" : nil, iat: issuedAt, exp: issuedAt + Int(lifetime),
                aud: "appstoreconnect-v1"))
        let signingInput = base64URL(header) + "." + base64URL(claims)
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
