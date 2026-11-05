import Foundation

/// Turns xcodebuild's output into a log a person can read, the way Xcode's build log does: each build task becomes
/// one readable line ("▸ Compile LegiloKit (arm64)", "▸ Sign Legilo.app") or nothing, and the raw invocation under
/// it (the `cd`, the `export`s, the compiler command line listing every source file) is dropped.
///
/// Fed one line at a time, in order; each call returns the lines to keep (none, the line itself, or a task's readable
/// line followed by it). Nothing that explains a build is dropped:
/// - every line a tool printed under a task (a compiler's errors, warnings and notes with their source excerpts, a
///   run script's output) is kept, preceded by the task's readable line so it has context;
/// - an invocation line that reads like a diagnostic (`error:`, `warning:`) is kept too;
/// - lines outside any task (xcodebuild's own messages, `** ARCHIVE FAILED **`, the list of failed commands, test
///   results) are kept, apart from a few kinds of package-resolution chatter.
///
/// Readable task lines start with `▸ `, which never starts an xcodebuild line, so condensing a condensed log changes
/// nothing.
public struct XcodebuildLogCondenser: Sendable {
    /// Marks a line the condenser wrote in place of a task's header.
    public static let taskMarker = "▸ "

    /// The steps whose output is xcodebuild's; other steps (scripts, git, Hangar's own) are kept as they are.
    public static func condenses(step: String) -> Bool {
        [StepName.archive, StepName.test, StepName.export].contains(step)
    }

    private enum Phase {
        /// Not inside a task.
        case outside
        /// After `Command line invocation:`, before the command.
        case commandLine
        /// Inside a task, reading its invocation (indented lines).
        case invocation
        /// Inside a task, after the first line a tool printed: everything is kept until the blank line.
        case output
    }

    private var phase = Phase.outside
    private var task: BuildTask?
    /// The compile task that ended at the last blank line, when nothing of it was written: the compiler's
    /// diagnostics may follow the blank line, and then they need its context.
    private var endedCompile: BuildTask?
    /// Whether the current task's readable line was written.
    private var announced = false
    /// Readable lines written once per kind and target (one "Compile Cmlx (arm64)" for many `CompileC`s).
    private var announcedKeys: Set<String> = []

    public init() {}

    /// The lines to keep for `line`, in order.
    public mutating func consume(_ line: String) -> [String] {
        if line.isEmpty {
            // A blank line ends a task; blank lines are not kept, the `▸` lines carry the structure.
            if phase != .commandLine { phase = .outside }
            if let task, task.kind == .compile, !announced { endedCompile = task }
            task = nil
            return []
        }
        let indented = line.first == " " || line.first == "\t"

        if !indented, let header = BuildTask(header: line) {
            return start(header)
        }

        switch phase {
        case .commandLine:
            phase = .outside
            guard indented else { return keepOutside(line) }
            return [Self.taskMarker + Self.commandLine(line.trimmingCharacters(in: .whitespaces))]
        case .outside:
            if let compile = endedCompile {
                endedCompile = nil
                if !indented, line.hasPrefix("/"), Self.isDiagnostic(line) {
                    return [Self.taskMarker + compile.context, line]
                }
            }
            return keepOutside(line)
        case .invocation:
            guard let task else { return keepOutside(line) }
            if task.kind == .script, line.hasPrefix("    /bin/sh -c ") {
                // What follows is the script's own output, however it is indented.
                phase = .output
                return []
            }
            if task.kind == .sign, let identity = Self.signingLine(line) { return [identity] }
            let isOutput = !indented || Self.isDiagnostic(line)
            if task.quietOutput && !Self.isDiagnostic(line) { return [] }
            guard isOutput else { return [] }
            phase = .output
            return announce() + [line]
        case .output:
            return announce() + [line]
        }
    }

    /// Condenses a whole log.
    public static func condense<Lines: Sequence>(_ lines: Lines) -> [String] where Lines.Element == String {
        var condenser = XcodebuildLogCondenser()
        return lines.flatMap { condenser.consume($0) }
    }

    /// Condenses the entries of the steps xcodebuild writes (each step on its own), keeping every entry's time and
    /// step; other steps' entries are kept as they are.
    public static func condense(_ entries: [LogEntry]) -> [LogEntry] {
        var condensers: [String: XcodebuildLogCondenser] = [:]
        var result: [LogEntry] = []
        result.reserveCapacity(entries.count / 4)
        for entry in entries {
            guard condenses(step: entry.step) else {
                result.append(entry)
                continue
            }
            for line in condensers[entry.step, default: XcodebuildLogCondenser()].consume(entry.line) {
                result.append(LogEntry(t: entry.t, step: entry.step, line: line))
            }
        }
        return result
    }

    // MARK: Tasks

    private mutating func start(_ header: BuildTask) -> [String] {
        task = header
        endedCompile = nil
        announced = false
        phase = header.kind == .commandLine ? .commandLine : .invocation
        if header.kind == .commandLine { return [] }
        guard header.mode == .visible else { return [] }
        if let key = header.onceKey {
            guard announcedKeys.insert(key).inserted else { return [] }
        }
        announced = true
        return [Self.taskMarker + header.title]
    }

    /// The current task's readable line, when it was not written yet: its output needs the context.
    private mutating func announce() -> [String] {
        guard let task, !announced else { return [] }
        announced = true
        return [Self.taskMarker + task.context]
    }

    private func keepOutside(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if Self.chatter.contains(where: { trimmed.hasPrefix($0) }) { return [] }
        if trimmed.hasPrefix("Checking out "), trimmed.contains(" of package ") { return [] }
        // A task named in a list (`The following build commands failed:`), read like its readable line.
        if line != trimmed, let listed = BuildTask(header: trimmed) {
            return [String(line.prefix { $0 == " " || $0 == "\t" }) + listed.context]
        }
        return [line]
    }

    /// Package resolution's progress lines: the `Resolved source packages:` list that follows says the same.
    private static let chatter = [
        "Updating from ", "Fetching from ", "Creating working copy of package ", "Cloning local copy of package ",
        "Computing version for ", "Computed ", "resolved source packages: ", "Build description signature: ",
        "Build description path: ",
    ]

    /// `/Applications/Xcode.app/…/xcodebuild archive -project …` → `xcodebuild archive -project …`.
    static func commandLine(_ command: String) -> String {
        guard let space = command.firstIndex(of: " ") else { return (command as NSString).lastPathComponent }
        let executable = String(command[..<space])
        guard executable.hasPrefix("/") else { return command }
        return (executable as NSString).lastPathComponent + command[space...]
    }

    /// `    Signing Identity:     "Apple Development: …"` → `  Signing Identity: "Apple Development: …"`.
    static func signingLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for label in ["Signing Identity:", "Provisioning Profile:"] where trimmed.hasPrefix(label) {
            let value = trimmed.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
            return "  \(label) \(value)"
        }
        return nil
    }

    /// `error: …`, `file:1:2: warning: …` and the like: never dropped, even from an invocation.
    static func isDiagnostic(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for word in ["error: ", "warning: ", "fatal error: "] {
            if trimmed.hasPrefix(word) || trimmed.contains(": " + word) { return true }
        }
        return false
    }
}

// MARK: - Task headers

extension XcodebuildLogCondenser {
    /// One of xcodebuild's task headers, such as
    /// `SwiftDriver LegiloKit normal arm64 com.apple.xcode.tools.swift.compiler (in target 'LegiloKit' from project 'Legilo')`.
    struct BuildTask: Sendable {
        enum Mode: Sendable {
            /// Its readable line is written when the task starts.
            case visible
            /// Written only before output the task prints.
            case silent
            /// Like `silent`, and of what it prints only diagnostics are kept (generated file contents, the target
            /// graph, App Intents chatter).
            case quiet
        }

        enum Kind: Sendable {
            case plain, compile, sign, script, commandLine
        }

        var mode: Mode
        var kind: Kind = .plain
        /// Of what the task prints, only diagnostics are kept: true for `quiet` tasks and for tools that print
        /// what they did (actool's file lists, the entitlements being signed in).
        var quietOutput = false
        /// The line written when the task starts (for a visible task).
        var title: String
        /// The line written before the task's output when `title` was not written for it.
        var context: String
        /// Visible tasks with the same key are announced once.
        var onceKey: String?

        /// Nil unless `line` is a task header: a known task name first, or a capitalised name followed later by
        /// `(in target '…' from project '…')`.
        init?(header line: String) {
            if line == "Command line invocation:" {
                self.init(mode: .silent, kind: .commandLine, title: "", context: "")
                return
            }
            guard let first = line.first, first.isUppercase else { return nil }
            let words = Self.words(line)
            guard let name = words.first, !name.isEmpty else { return nil }
            let target = Self.target(in: line)
            let known = Self.known[name] ?? Self.knownLines[line]
            guard known != nil || (target != nil && name.allSatisfy({ $0.isLetter || $0.isNumber }) && !name.contains(" "))
            else { return nil }
            let arguments = Array(words.dropFirst())
            self = Self.describe(name: name, arguments: arguments, target: target, mode: known ?? .silent)
            quietOutput = mode == .quiet || Self.quietOutputNames.contains(name)
        }

        static let quietOutputNames: Set<String> = [
            "CompileAssetCatalog", "CompileAssetCatalogVariant", "LinkAssetCatalog", "ProcessProductPackaging",
            "ProcessProductPackagingDER", "GenerateAssetSymbols",
        ]

        private init(mode: Mode, kind: Kind = .plain, title: String, context: String, onceKey: String? = nil) {
            self.mode = mode
            self.kind = kind
            self.title = title
            self.context = context
            self.onceKey = onceKey
        }

        /// Tasks known by name, and how much of them to show.
        static let known: [String: Mode] = {
            var modes: [String: Mode] = [:]
            for name in [
                "SwiftDriver", "CompileC", "CompileMetalFile", "Ld", "CodeSign", "PhaseScriptExecution",
                "GenerateDSYMFile", "CompileAssetCatalog", "CompileAssetCatalogVariant", "CompileStoryboard",
                "CompileXIB", "Libtool",
            ] { modes[name] = .visible }
            for name in [
                "SwiftCompile", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements",
                "SwiftDriverJobDiscovery", "SwiftEmitModule", "SwiftGeneratePch", "SwiftMergeGeneratedHeaders",
                "SwiftExplicitDependencyGeneratePcm", "SwiftExplicitDependencyCompileModule", "SwiftVerifyEmittedModuleInterface",
                "ScanDependencies", "PrecompileModule", "PrecompileSwiftBridgingHeader", "ProcessInfoPlistFile",
                "Copy", "CpResource", "CpHeader", "CopyPNGFile", "CopyStringsFile", "CopyPlistFile", "CopySwiftLibs",
                "CopyXCFramework", "ProcessXCFramework", "SymLink", "SetOwnerAndGroup", "SetMode", "MkDir", "Touch",
                "Strip", "CreateBuildDirectory", "CreateUniversalBinary", "RegisterExecutionPolicyException",
                "RegisterWithLaunchServices", "ProcessProductPackaging", "ProcessProductPackagingDER", "Validate",
                "ValidateEmbeddedBinary", "GenerateAssetSymbols", "LinkAssetCatalog", "MetalLink", "ReadFileContents",
                "PruneExplicitPrecompiledModules", "GenerateTAPI", "LinkStoryboards", "CompileSwiftSources",
                "ProcessPCH", "ProcessPCH++", "Ditto", "PBXCp", "Preprocess", "CopyPlistFile",
            ] { modes[name] = .silent }
            for name in [
                "WriteAuxiliaryFile", "ComputeTargetDependencyGraph", "ComputePackagePrebuildTargetDependencyGraph",
                "CreateBuildDescription", "CreateBuildRequest", "SendProjectDescription", "CreateBuildOperation",
                "GatherProvisioningInputs", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining", "ClangStatCache",
                "ExecuteExternalTool", "ComputeTargetDependencyGraph",
            ] { modes[name] = .quiet }
            return modes
        }()

        /// Headers of more than one word that are not tasks with arguments.
        static let knownLines: [String: Mode] = ["Prepare packages": .quiet, "Prepare build": .quiet]

        static func describe(name: String, arguments: [String], target: String?, mode: Mode) -> BuildTask {
            let paths = arguments.filter { $0.hasPrefix("/") }
            let file = paths.first.map { ($0 as NSString).lastPathComponent }
            let arch = arguments.first { Self.architectures.contains($0) }
            let archSuffix = arch.map { " (\($0))" } ?? ""
            let inTarget = target.map { " (\($0))" } ?? ""

            switch name {
            case "SwiftDriver":
                let module = target ?? arguments.first ?? "Swift sources"
                let title = "Compile \(module)\(archSuffix)"
                return BuildTask(mode: mode, title: title, context: title, onceKey: "compile|\(module)|\(arch ?? "")")
            case "CompileC":
                let unit = target ?? file ?? "C sources"
                let source = paths.dropFirst().first.map { ($0 as NSString).lastPathComponent } ?? file ?? unit
                return BuildTask(
                    mode: mode, kind: .compile, title: "Compile \(unit)\(archSuffix)", context: "Compile \(source)\(inTarget)",
                    onceKey: "compile|\(unit)|\(arch ?? "")")
            case "CompileMetalFile":
                return BuildTask(
                    mode: mode, kind: .compile, title: "Compile Metal shaders\(inTarget)", context: "Compile \(file ?? "shader")\(inTarget)",
                    onceKey: "metal|\(target ?? "")")
            case "CompileAssetCatalog", "CompileAssetCatalogVariant":
                return BuildTask(
                    mode: mode, title: "Compile asset catalog\(inTarget)", context: "Compile asset catalog\(inTarget)",
                    onceKey: "assets|\(target ?? "")")
            case "Ld":
                let product = file ?? target ?? "product"
                // Package targets are prelinked into object files first: only the real products are announced.
                let isObject = product.hasSuffix(".o")
                let title = "Link \(product)\(archSuffix)"
                return BuildTask(mode: isObject ? .silent : mode, title: title, context: title)
            case "Libtool":
                let title = "Archive \(file ?? target ?? "library")\(archSuffix)"
                return BuildTask(mode: mode, title: title, context: title)
            case "CodeSign":
                let title = "Sign \(file ?? target ?? "product")"
                return BuildTask(mode: mode, kind: .sign, title: title, context: title)
            case "PhaseScriptExecution":
                let script = arguments.first ?? "script"
                let title = "Run script '\(script)'\(inTarget)"
                return BuildTask(mode: mode, kind: .script, title: title, context: title)
            case "GenerateDSYMFile":
                let title = "Generate \(file ?? "dSYM")"
                return BuildTask(mode: mode, title: title, context: title)
            case "SwiftCompile":
                let context = "Compile \(Self.compiledFiles(arguments) ?? file ?? "Swift sources")\(inTarget)"
                return BuildTask(mode: mode, kind: .compile, title: context, context: context)
            default:
                let verb = Self.verbs[name] ?? name
                let object = file ?? arguments.first { !$0.isEmpty && !Self.variants.contains($0) && !Self.architectures.contains($0) }
                let context = [verb, object].compactMap { $0 }.joined(separator: " ") + inTarget
                return BuildTask(mode: mode, title: context, context: context)
            }
        }

        static let architectures: Set<String> = ["arm64", "arm64e", "x86_64", "i386", "armv7k", "arm64_32", "undefined_arch"]
        static let variants: Set<String> = ["normal", "debug", "profile"]

        static let verbs: [String: String] = [
            "Copy": "Copy", "CpResource": "Copy", "CpHeader": "Copy", "CopyPNGFile": "Copy", "CopyStringsFile": "Copy",
            "CopyPlistFile": "Copy", "CopySwiftLibs": "Copy Swift libraries", "ProcessInfoPlistFile": "Process",
            "SymLink": "Link", "MkDir": "Create", "Touch": "Touch", "Strip": "Strip",
            "CreateUniversalBinary": "Create universal binary", "Validate": "Validate",
            "ValidateEmbeddedBinary": "Validate", "PrecompileModule": "Precompile",
            "SwiftEmitModule": "Emit Swift module", "SwiftMergeGeneratedHeaders": "Merge Swift headers",
            "ExtractAppIntentsMetadata": "Extract App Intents metadata", "AppIntentsSSUTraining": "Train App Shortcuts",
            "ProcessProductPackaging": "Process entitlements", "ProcessProductPackagingDER": "Process entitlements",
            "GenerateAssetSymbols": "Generate asset symbols", "LinkAssetCatalog": "Link asset catalog",
            "MetalLink": "Link Metal library", "WriteAuxiliaryFile": "Write", "CreateBuildDirectory": "Create",
            "ScanDependencies": "Scan dependencies of", "RegisterExecutionPolicyException": "Register",
            "ComputeTargetDependencyGraph": "Compute the target graph", "ExecuteExternalTool": "Run",
            "GatherProvisioningInputs": "Gather provisioning inputs", "CreateBuildDescription": "Create the build description",
        ]

        /// `Compiling\ A.swift,\ B.swift` (already unescaped to `Compiling A.swift, B.swift` by `words`): "A.swift,
        /// B.swift", or "12 files" for a long list.
        static func compiledFiles(_ arguments: [String]) -> String? {
            guard let list = arguments.first(where: { $0.hasPrefix("Compiling ") }) else { return nil }
            let files = list.dropFirst("Compiling ".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if files.count > 3 { return "\(files.count) files" }
            return files.joined(separator: ", ")
        }

        /// The target in `(in target 'LegiloKit' from project 'Legilo')`.
        static func target(in line: String) -> String? {
            guard let start = line.range(of: " (in target '") else { return nil }
            let rest = line[start.upperBound...]
            guard let end = rest.firstIndex(of: "'") else { return nil }
            return String(rest[..<end])
        }

        /// The words before ` (in target`, split at unescaped spaces and unescaped (`Compiling\ A.swift` is one word).
        static func words(_ line: String) -> [String] {
            let head = line.range(of: " (in target '").map { line[..<$0.lowerBound] } ?? line[...]
            var words: [String] = []
            var current = ""
            var escaped = false
            for character in head {
                if escaped {
                    current.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == " " {
                    if !current.isEmpty { words.append(current) }
                    current = ""
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { words.append(current) }
            return words
        }
    }
}
