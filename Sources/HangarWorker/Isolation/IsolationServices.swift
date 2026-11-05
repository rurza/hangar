import Foundation
import HangarCore
import OpenDirectory
import Security

/// Where `hangar-worker isolate` keeps the generated `hangar` password: the administrator's own login keychain, so
/// they can look it up later. Neither the server nor the worker reads it.
public protocol AccountPasswordStore: Sendable {
    /// Adds or replaces the password for `account` under `service`.
    func save(_ password: SensitiveText, account: String, service: String) throws
}

/// Checks a local account's password without putting it on a command line.
public protocol AccountPasswordVerifier: Sendable {
    func verify(_ password: SensitiveText, user: String) -> Bool
}

/// Generates the `hangar` password.
public protocol PasswordGenerating: Sendable {
    func generate() -> SensitiveText
}

/// The keychain item `isolate` writes.
public enum AccountPasswordItem {
    public static let service = "app.hangar.worker-account"
    public static let label = "Hangar build account"

    /// The command that prints it again.
    public static func lookupCommand(account: String) -> String {
        "security find-generic-password -s \(service) -a \(account) -w"
    }
}

/// A generic password item in the login keychain of the user running `isolate`, written with Security.framework so
/// the password never appears in a process's arguments.
public struct LoginKeychainPasswordStore: AccountPasswordStore {
    public init() {}

    public struct Failure: Error, CustomStringConvertible {
        public var status: OSStatus
        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Could not save the password in your login keychain: \(message)"
        }
    }

    public func save(_ password: SensitiveText, account: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(password.value.utf8)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: AccountPasswordItem.label]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = AccountPasswordItem.label
        item[kSecAttrDescription as String] = "Password of the macOS user that runs Hangar builds"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }
}

/// Verifies through Open Directory, in this process: an authentication check, no root needed, nothing on argv.
public struct OpenDirectoryPasswordVerifier: AccountPasswordVerifier {
    public init() {}

    public func verify(_ password: SensitiveText, user: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
            try record.verifyPassword(password.value)
            return true
        } catch {
            return false
        }
    }
}

/// Five groups of four lowercase letters and digits, without look-alikes (0/o, 1/l/i): about 100 bits, and easy
/// to type in an emergency. From the system's cryptographic generator. Also the CI keychain's password, which
/// `security -i` then takes without quoting.
public struct RandomPasswordGenerator: PasswordGenerating {
    public static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    public static let groups = 5
    public static let groupLength = 4

    public init() {}

    public func generate() -> SensitiveText {
        var generator = SystemRandomNumberGenerator()
        return Self.generate(using: &generator)
    }

    static func generate<G: RandomNumberGenerator>(using generator: inout G) -> SensitiveText {
        let groups = (0..<Self.groups).map { _ in
            String((0..<groupLength).map { _ in alphabet.randomElement(using: &generator)! })
        }
        return SensitiveText(groups.joined(separator: "-"))
    }
}
