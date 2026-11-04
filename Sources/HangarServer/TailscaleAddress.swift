import Foundation
import HangarCore

/// Finds the address the server binds in production: this Mac's Tailscale IPv4.
public enum TailscaleAddress {
    /// The app-bundle binary first (the CLI is rarely on PATH for a launchd agent), then `tailscale` from PATH.
    static let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "tailscale"]

    /// The first IPv4 line printed by `tailscale ip -4`, or nil when Tailscale is missing, stopped or prints nothing usable.
    public static func detect(runner: any ProcessRunner) async -> String? {
        for executable in candidates {
            let command = ProcessCommand(executable: executable, arguments: ["ip", "-4"])
            guard let outcome = try? await runner.run(command, onLine: { _ in }), outcome.exitCode == 0 else { continue }
            let address = outcome.output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: isIPv4)
            if let address { return address }
        }
        return nil
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && Int(part)! <= 255
        }
    }
}
