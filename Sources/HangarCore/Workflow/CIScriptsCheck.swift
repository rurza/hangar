import Foundation

/// A shell script in the repository's `ci_scripts`, as the deploy check reads it.
public struct CIScript: Equatable, Sendable {
    /// The file name, such as `ci_post_clone.sh`.
    public var name: String
    public var text: String
    public var executable: Bool

    public init(name: String, text: String, executable: Bool) {
        self.name = name
        self.text = text
        self.executable = executable
    }
}

/// Static checks of `ci_scripts/*.sh` before a deploy: variables the scripts read that nothing defines, and hook
/// scripts without the executable bit. A plain scan, not a shell parser, tuned to say nothing rather than something
/// wrong:
/// - only `$NAME` and `${NAME}` with an upper-case name of two or more characters count (lower-case names are the
///   scripts' own); `${NAME:-default}` and the like supply their own value and do not;
/// - nothing inside single quotes, in a comment, or escaped as `\$`;
/// - a name any of the scripts assigns (`NAME=`, `export NAME=`, `for NAME in`, `read NAME`) is defined;
/// - every `CI_*` name, what Hangar sets for every job, and the usual shell and macOS variables are defined.
public enum CIScriptsCheck {
    /// The hooks Hangar runs; Xcode Cloud requires each to be executable.
    public static let hooks: Set<String> = ["ci_post_clone.sh", "ci_pre_xcodebuild.sh", "ci_post_xcodebuild.sh"]

    /// Set by Hangar for every job or by the shell itself.
    static let standardNames: Set<String> = [
        "CI", "HOME", "PATH", "USER", "LOGNAME", "SHELL", "TMPDIR", "PWD", "OLDPWD", "LANG", "LC_ALL", "LC_CTYPE",
        "TERM", "IFS", "HOSTNAME", "HOSTTYPE", "UID", "EUID", "PPID", "RANDOM", "SECONDS", "LINENO", "OSTYPE",
        "MACHTYPE", "BASH", "BASH_SOURCE", "BASH_VERSION", "BASH_REMATCH", "BASHPID", "FUNCNAME", "PIPESTATUS",
        "OPTARG", "OPTIND", "REPLY", "SHLVL", "EPOCHSECONDS", "ZSH_VERSION", "DEVELOPER_DIR", "GIT_TERMINAL_PROMPT",
    ]

    public struct Warnings: Equatable, Sendable {
        /// Script name → the names it reads that nothing defines, sorted.
        public var undefined: [String: [String]]
        /// Hook scripts without the executable bit, sorted.
        public var notExecutable: [String]

        public init(undefined: [String: [String]], notExecutable: [String]) {
            self.undefined = undefined
            self.notExecutable = notExecutable
        }
    }

    public static func check(_ scripts: [CIScript], definedNames: Set<String>) -> Warnings {
        var assigned = Set<String>()
        var references: [String: Set<String>] = [:]
        for script in scripts {
            let scan = scan(script.text)
            assigned.formUnion(scan.assigned)
            references[script.name] = scan.referenced
        }
        var undefined: [String: [String]] = [:]
        for (name, referenced) in references {
            let missing = referenced.filter { variable in
                !variable.hasPrefix("CI_") && !standardNames.contains(variable) && !definedNames.contains(variable)
                    && !assigned.contains(variable)
            }
            if !missing.isEmpty { undefined[name] = missing.sorted() }
        }
        let notExecutable = scripts.filter { hooks.contains($0.name) && !$0.executable }.map(\.name).sorted()
        return Warnings(undefined: undefined, notExecutable: notExecutable)
    }

    /// The names `text` reads (as counted above) and the names it assigns.
    static func scan(_ text: String) -> (referenced: Set<String>, assigned: Set<String>) {
        var referenced = Set<String>()
        var assigned = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = Array(rawLine)
            assigned.formUnion(assignments(in: String(rawLine)))
            var index = 0
            var singleQuoted = false
            var doubleQuoted = false
            var previous: Character = " "
            while index < line.count {
                let character = line[index]
                defer { previous = character; index += 1 }
                if singleQuoted {
                    if character == "'" { singleQuoted = false }
                    continue
                }
                switch character {
                case "\\":
                    index += 1  // The next character is literal.
                case "'" where !doubleQuoted:
                    singleQuoted = true
                case "\"":
                    doubleQuoted.toggle()
                case "#" where !doubleQuoted && (previous == " " || previous == "\t" || index == 0):
                    index = line.count  // A comment runs to the end of the line.
                case "$":
                    if let name = reference(in: line, at: index + 1) { referenced.insert(name) }
                default:
                    break
                }
            }
        }
        return (referenced.filter(isEnvironmentName), assigned)
    }

    /// The variable `$` at `start - 1` reads, unless it supplies its own value (`${NAME:-x}`, `${NAME=x}`, …).
    private static func reference(in line: [Character], at start: Int) -> String? {
        guard start < line.count else { return nil }
        if line[start] == "{" {
            var index = start + 1
            var name = ""
            while index < line.count, isNameCharacter(line[index]) {
                name.append(line[index])
                index += 1
            }
            guard !name.isEmpty, index < line.count else { return nil }
            let next = line[index]
            if next == "}" { return name }
            if next == ":", index + 1 < line.count, "-=+".contains(line[index + 1]) { return nil }
            if "-=+".contains(next) { return nil }
            return name
        }
        guard line[start].isLetter || line[start] == "_" else { return nil }
        var index = start
        var name = ""
        while index < line.count, isNameCharacter(line[index]) {
            name.append(line[index])
            index += 1
        }
        return name
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }

    /// Upper-case, two or more characters: how environment variables are named.
    static func isEnvironmentName(_ name: String) -> Bool {
        name.count >= 2 && name.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
            && !(name.first?.isNumber ?? true)
    }

    private static var assignmentPatterns: [Regex<(Substring, Substring)>] { [
        /(?:^|[;&|(\s])(?:export\s+|local\s+|readonly\s+|declare\s+(?:-\w+\s+)*|typeset\s+(?:-\w+\s+)*)?([A-Za-z_][A-Za-z0-9_]*)\+?=/,
        /(?:^|[;&|\s])for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b/,
    ] }

    /// Names the line assigns: `NAME=`, `export NAME=`, `for NAME in`, and the names after `read`.
    static func assignments(in line: String) -> Set<String> {
        var names = Set<String>()
        for pattern in assignmentPatterns {
            for match in line.matches(of: pattern) { names.insert(String(match.output.1)) }
        }
        if let match = line.firstMatch(of: /(?:^|[;&|\s])read\s+((?:-\w+\s+)*)([A-Za-z_][A-Za-z0-9_\s]*)/) {
            for word in match.output.2.split(whereSeparator: \.isWhitespace) { names.insert(String(word)) }
        }
        // `export NAME` alone marks a name the script expects from outside; it defines nothing.
        return names
    }

    /// One sentence per problem, for the deploy sheet: undefined variables first (by script), then hooks that are
    /// not executable.
    /// `onlyFor` maps a name the app sets only for some workflows to those workflows: the sentence says so, as the
    /// deployed workflow is not among them.
    public static func sentences(
        _ warnings: Warnings, directory: String = "ci_scripts", onlyFor: [String: [String]] = [:]
    ) -> [String] {
        var lines: [String] = []
        for script in warnings.undefined.keys.sorted() {
            let names = warnings.undefined[script] ?? []
            let list = listText(names.map { "$\($0)" })
            let one = names.count == 1
            let elsewhere = names.compactMap { name in
                onlyFor[name].flatMap { $0.isEmpty ? nil : "\(one ? "" : "$\(name) ")only for \(listText($0.map { "“\($0)”" }))" }
            }
            if !elsewhere.isEmpty {
                lines.append(
                    "\(directory)/\(script) uses \(list), which \(one ? "isn’t" : "aren’t") defined in Hangar for this workflow (\(elsewhere.joined(separator: "; "))): add \(one ? "it" : "them") for this workflow too, or the script sees \(one ? "it" : "them") empty.")
                continue
            }
            lines.append(
                "\(directory)/\(script) uses \(list), which \(one ? "isn’t" : "aren’t") defined in Hangar: add \(one ? "it" : "them") under Variables, or the script sees \(one ? "it" : "them") empty.")
        }
        for script in warnings.notExecutable {
            lines.append(
                "\(directory)/\(script) isn’t executable: Hangar runs it with /bin/sh, but Xcode Cloud requires chmod +x (commit the mode with git update-index --chmod=+x).")
        }
        return lines
    }

    private static func listText(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
