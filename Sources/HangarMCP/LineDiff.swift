/// A unified diff of two texts by lines, for `set_workflow`'s preview. Workflow files are at most 64 KB, so the
/// quadratic longest-common-subsequence table is small.
enum LineDiff {
    private enum Edit: Equatable {
        case same(String), removed(String), added(String)
    }

    /// "" when the texts are equal; otherwise `--- old` / `+++ new` and hunks with `context` lines around changes.
    static func unified(_ old: String, _ new: String, oldLabel: String, newLabel: String, context: Int = 3) -> String {
        let a = lines(old), b = lines(new)
        let edits = Self.edits(a, b)
        guard edits.contains(where: { if case .same = $0 { false } else { true } }) else { return "" }
        var output = ["--- \(oldLabel)", "+++ \(newLabel)"]
        // Positions (in old and new) before each edit, for the hunk headers.
        var positions: [(Int, Int)] = []
        var i = 0, j = 0
        for edit in edits {
            positions.append((i, j))
            switch edit {
            case .same: i += 1; j += 1
            case .removed: i += 1
            case .added: j += 1
            }
        }
        let changed = edits.indices.filter { if case .same = edits[$0] { false } else { true } }
        var hunkStart = 0
        while hunkStart < changed.count {
            var hunkEnd = hunkStart
            while hunkEnd + 1 < changed.count, changed[hunkEnd + 1] - changed[hunkEnd] <= 2 * context + 1 { hunkEnd += 1 }
            let first = max(0, changed[hunkStart] - context)
            let last = min(edits.count - 1, changed[hunkEnd] + context)
            var oldCount = 0, newCount = 0
            var body: [String] = []
            for index in first...last {
                switch edits[index] {
                case .same(let line): body.append(" " + line); oldCount += 1; newCount += 1
                case .removed(let line): body.append("-" + line); oldCount += 1
                case .added(let line): body.append("+" + line); newCount += 1
                }
            }
            let (oldStart, newStart) = positions[first]
            output.append("@@ -\(range(oldStart, oldCount)) +\(range(newStart, newCount)) @@")
            output += body
            hunkStart = hunkEnd + 1
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static func range(_ start: Int, _ count: Int) -> String {
        count == 0 ? "\(start),0" : count == 1 ? "\(start + 1)" : "\(start + 1),\(count)"
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func edits(_ a: [String], _ b: [String]) -> [Edit] {
        // lcs[i][j]: the longest common subsequence of a[i...] and b[j...].
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var edits: [Edit] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                edits.append(.same(a[i])); i += 1; j += 1
            } else if i < a.count, j == b.count || lcs[i + 1][j] >= lcs[i][j + 1] {
                edits.append(.removed(a[i])); i += 1
            } else {
                edits.append(.added(b[j])); j += 1
            }
        }
        return edits
    }
}
