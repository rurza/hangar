/// Column-aligned plain text: two spaces between columns, no trailing spaces, no trailing newline.
struct Table {
    var headers: [String]
    var rows: [[String]]

    /// `bold` emboldens the header row with ANSI codes; pass it only when stdout is a terminal.
    func render(bold: Bool = false) -> String {
        let all = [headers] + rows
        let columns = all.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in
            all.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0
        }
        let lines = all.enumerated().map { index, row in
            var line = row.enumerated().map { column, cell in
                cell + String(repeating: " ", count: widths[column] - cell.count)
            }.joined(separator: "  ")
            while line.last == " " { line.removeLast() }
            return index == 0 && bold ? "\u{1B}[1m\(line)\u{1B}[0m" : line
        }
        return lines.joined(separator: "\n")
    }

    /// `label  value` lines with the values aligned.
    static func keyValue(_ pairs: [(String, String)]) -> String {
        let width = pairs.map(\.0.count).max() ?? 0
        return pairs.map { $0 + String(repeating: " ", count: width - $0.count) + "  " + $1 }.joined(separator: "\n")
    }
}
