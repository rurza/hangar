import Foundation
import HangarCore

/// Finds the address the server binds in production: this Mac's Tailscale IPv4.
public enum TailscaleAddress {
    /// The app-bundle binary, then the Homebrew CLI (Apple Silicon, then Intel), then `tailscale` from PATH.
    /// A launchd agent's PATH is only `/usr/bin:/bin:/usr/sbin:/sbin`, so the absolute locations come first.
    static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
        "tailscale",
    ]

    /// The first IPv4 line printed by `tailscale ip -4`, or nil when Tailscale is missing, stopped or prints nothing usable.
    public static func detect(
        runner: any ProcessRunner, fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) async -> String? {
        for executable in candidates {
            // Absolute candidates that are not installed are skipped without spawning a process.
            if executable.hasPrefix("/") && !fileExists(executable) { continue }
            let command = ProcessCommand(executable: executable, arguments: ["ip", "-4"])
            guard let outcome = try? await runner.run(command, onLine: { _ in }), outcome.exitCode == 0 else { continue }
            let address = outcome.output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: isIPv4)
            if let address { return address }
        }
        return nil
    }

    /// Retries `detect` every `interval` until `timeout` has passed, because at login Tailscale may not be up yet.
    /// Tries at least once. Nil when no address showed up in time.
    public static func waitForAddress(
        runner: any ProcessRunner, timeout: Duration = .seconds(60), interval: Duration = .seconds(2),
        clock: any Clock<Duration> = ContinuousClock(),
        fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) async -> String? {
        var waited = Duration.zero
        while true {
            if let address = await detect(runner: runner, fileExists: fileExists) { return address }
            guard waited + interval <= timeout else { return nil }
            do { try await clock.sleep(for: interval) } catch { return nil }
            waited += interval
        }
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && Int(part)! <= 255
        }
    }
}
