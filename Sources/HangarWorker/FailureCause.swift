import Foundation

/// Picks the line of a step's log that best explains why the step failed, so the build page can say
/// "AnalyticsClient+Live.swift:19:35: error: cannot find 'analyticsDSN' in scope" instead of "xcodebuild exited with 65".
///
/// Lines are fed one at a time as they are logged (already masked); only the best candidate so far and the last line
/// are kept. Candidates, best first:
/// 1. a known failure signature, explained (dsymutil's lipo not finding its temporary DWARF files);
/// 2. a compiler or tool error (`error: …`, `file.swift:1:2: error: …`), the first one;
/// 3. the command xcodebuild lists under "The following build commands failed:";
/// 4. a fatal or shell error (`fatal: …`, "No such file or directory", "command not found", …), the first one.
///
/// `fallbackToLastLine` (for hook scripts, whose own messages follow no convention) adds the last non-empty line.
struct FailureCause: Sendable {
    static let maxLength = 300

    private var best: (rank: Int, line: String)?
    private var last: String?
    private var expectFailedCommand = false
    private var sawMissingDWARF = false

    mutating func consume(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        defer { if !Self.isBanner(line) { last = line } }

        if expectFailedCommand {
            expectFailedCommand = false
            offer(3, line)
        }
        if line.hasPrefix("The following build commands failed:") {
            expectFailedCommand = true
            return
        }
        if line.hasPrefix("lipo: warning: file not found"), line.contains("/dsym-") { sawMissingDWARF = true }
        if sawMissingDWARF, line.hasPrefix("lipo: no eligible inputs found") {
            offer(1, "dSYM generation failed: lipo could not find the temporary DWARF files dsymutil writes to TMPDIR")
            return
        }
        if Self.isToolError(line) {
            offer(2, line)
        } else if Self.isOtherError(line) {
            offer(4, line)
        }
    }

    /// The best line, shortened; nil when none qualified.
    func line(fallbackToLastLine: Bool = false) -> String? {
        (best?.line ?? (fallbackToLastLine ? last : nil)).map(Self.shortened)
    }

    private mutating func offer(_ rank: Int, _ line: String) {
        if let best, best.rank <= rank { return }
        // `error: lipo:` and the like say nothing on their own.
        if rank == 2, line.hasSuffix(":") { return }
        best = (rank, line)
    }

    /// `error: …`, or `<anything>: error: …` (clang, swiftc, ld, xcodebuild).
    static func isToolError(_ line: String) -> Bool {
        line.hasPrefix("error: ") || line.contains(": error: ") || line.hasPrefix("xcodebuild: error:")
    }

    private static let otherErrors = [
        "fatal: ", "No such file or directory", "command not found", "binary operator expected", "Permission denied",
        "unbound variable", "Couldn't find", "Could not find", "Segmentation fault",
    ]

    static func isOtherError(_ line: String) -> Bool {
        otherErrors.contains { line.contains($0) }
    }

    /// `** ARCHIVE FAILED **` and its kind: they only repeat the exit status.
    static func isBanner(_ line: String) -> Bool { line.hasPrefix("** ") && line.hasSuffix(" **") }

    /// `/long/path/File.swift:19:35: error: …` → `File.swift:19:35: error: …`; capped at `maxLength`.
    static func shortened(_ line: String) -> String {
        var text = line
        if text.hasPrefix("/"), let colon = text.firstIndex(of: ":") {
            let path = text[..<colon]
            if let slash = path.lastIndex(of: "/") { text = String(text[text.index(after: slash)...]) }
        }
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }
}
