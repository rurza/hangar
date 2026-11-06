import Foundation
import HangarCore

/// Generates a password: a VM guest's admin password, a job keychain's.
public protocol PasswordGenerating: Sendable {
    func generate() -> SensitiveText
}

/// Five groups of four lowercase letters and digits, without look-alikes (0/o, 1/l/i): about 100 bits. From the
/// system's cryptographic generator. `security -i` takes it without quoting, which a job keychain's password relies on.
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

/// The worker's launchd agent, as the install script writes it: the worker runs as the Mac's owner, in their login
/// session.
public enum WorkerLaunchAgent {
    public static let label = "app.hangar.worker"
}
