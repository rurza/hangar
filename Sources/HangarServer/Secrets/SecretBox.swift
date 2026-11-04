import CryptoKit
import Foundation

/// AES-GCM sealing for variable values; the stored form is the `combined` nonce + ciphertext + tag.
public struct SecretBox: Sendable {
    private let key: SymmetricKey

    public init(key: SymmetricKey) { self.key = key }

    public func seal(_ plaintext: String) throws -> Data {
        // `combined` is only nil for non-standard nonce sizes; ours is the default 12 bytes.
        try AES.GCM.seal(Data(plaintext.utf8), using: key).combined!
    }

    public func open(_ sealed: Data) throws -> String {
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw CryptoKitError.incorrectParameterSize
        }
        return text
    }
}
