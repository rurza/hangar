import Foundation
import Yams

public enum WorkflowDetectionError: Error, Equatable, Sendable {
    /// No Xcode workspace, project or XcodeGen `project.yml` outside the ignored directories.
    case noProjectFound
}

/// Works out a workflow file from a repository's file listing and a few of its files, without fetching anything:
/// `filesToFetch` says which files it wants (ask again after fetching them, as some depend on others), `suggest`
/// builds the suggestion from what was fetched. Missing files only make the guesses rougher.
public enum WorkflowDetector {
    static let workflowName = "release"
    static let placeholderXcode = "27.2"
    static let ignoredDirectories: Set<String> = ["Pods", "Carthage", ".build", "DerivedData", "node_modules", ".swiftpm"]
    static let ciScriptNames = ["ci_post_clone.sh", "ci_pre_xcodebuild.sh"]
    /// Shared schemes whose target is unknown by name; each costs a request.
    static let maxSchemeFetches = 3
    /// Apps whose `.appiconset` Contents.json is fetched.
    static let maxIconFetches = 4
    /// How many files a reader fetches in all beyond the commit and the tree, and in how many rounds of
    /// `filesToFetch` (shared by the server and the tests).
    public static let maxFileFetches = 9
    public static let maxFetchRounds = 4
    /// Text files bigger than this are not fetched.
    public static let maxTextBytes = 8 * 1024 * 1024
    /// Icon images bigger than this are not served.
    public static let maxImageBytes = 5 * 1024 * 1024

    /// Paths to fetch (with the contents API) to refine the suggestion, given the files fetched so far.
    public static func filesToFetch(tree: RepositoryTree, files: [String: String]) -> [String] {
        (try? Analysis(tree: tree, files: files))?.wanted ?? []
    }

    /// With `bundleIDs` (the app's, from App Store Connect), only the schemes of the app with one of them are
    /// archived, when the repository builds several apps.
    public static func suggest(
        tree: RepositoryTree, files: [String: String], machines: [Machine], now: Date = Date(), commit: String = "",
        bundleIDs: [String]? = nil
    ) throws(WorkflowDetectionError) -> WorkflowSuggestion {
        var analysis = try Analysis(tree: tree, files: files)
        let picked = bundleIDs.flatMap { ids in analysis.apps.first { !Set($0.bundleIDs).isDisjoint(with: ids) } }
        if picked == nil, analysis.apps.count > 1 {
            analysis.notes.append(
                "The repository builds \(analysis.apps.count) apps (\(analysis.apps.map(\.name).joined(separator: ", "))): every app's schemes are archived, so remove the ones that are not this app's.")
        }
        if let app = picked, analysis.apps.count > 1 {
            let names = Set(app.schemes.map(\.name))
            let actions = analysis.actions.filter { names.contains($0.scheme) }
            if !actions.isEmpty {
                analysis.actions = actions
                analysis.icon = app.icon ?? analysis.icon
            }
        }
        var notes = analysis.notes
        let xcode = xcodeVersion(machines: machines, now: now, notes: &notes)
        notes.append("Exports for App Store Connect; switch the export to Developer ID for apps distributed outside the Mac App Store.")
        notes.append("Turn on TestFlight upload in the editor when you're ready.")
        if tree.truncated {
            notes.append("The repository is too large for GitHub to list in full, so some files may have been missed.")
        }
        let workflow = Workflow(
            project: analysis.layout.kind == .workspace ? nil : analysis.layout.container,
            workspace: analysis.layout.kind == .workspace ? analysis.layout.container : nil,
            xcode: xcode, teamID: analysis.team, tools: analysis.tools, actions: analysis.actions)
        let file = WorkflowFile(version: 1, workflows: [workflowName: workflow])
        let usable = tree.paths.filter(isUsable)
        let testPlans = Set(usable.filter { $0.hasSuffix(".xctestplan") }.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension })
        let projectDirectory = analysis.layout.directory
        let whatToTestPrefix = projectDirectory.isEmpty ? "TestFlight/WhatToTest." : "\(projectDirectory)/TestFlight/WhatToTest."
        let whatToTestFiles = usable.filter {
            $0.hasPrefix(whatToTestPrefix) && $0.hasSuffix(".txt") && $0.count > whatToTestPrefix.count + 4
                && !$0.dropFirst(whatToTestPrefix.count).contains("/")
        }
        return WorkflowSuggestion(
            commit: commit, yaml: WorkflowYAMLWriter.yaml(file), notes: notes, workflows: file,
            schemes: analysis.schemes.sorted { $0.name < $1.name }, icon: analysis.icon, hasWorkflowFile: tree.hasWorkflowFile,
            projects: analysis.projects, testPlans: testPlans.sorted(), whatToTestFiles: whatToTestFiles.sorted())
    }

    /// The apps the repository builds, without App Store Connect matches (see `matchAppStoreConnect`).
    public static func inspect(
        tree: RepositoryTree, files: [String: String], commit: String = ""
    ) throws(WorkflowDetectionError) -> RepositoryInspection {
        let analysis = try Analysis(tree: tree, files: files)
        var notes = analysis.notes
        if tree.truncated {
            notes.append("The repository is too large for GitHub to list in full, so some files may have been missed.")
        }
        return RepositoryInspection(
            commit: commit, apps: analysis.apps, projects: analysis.projects, notes: notes,
            hasWorkflowFile: tree.hasWorkflowFile)
    }

    /// Each app with the App Store Connect app that has one of its bundle IDs, named as there; matched apps first.
    public static func matchAppStoreConnect(_ apps: [DetectedApp], ascApps: [ASCAppSummary]) -> [DetectedApp] {
        let byBundleID = Dictionary(ascApps.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        var matched: [DetectedApp] = []
        var unmatched: [DetectedApp] = []
        for var app in apps {
            if let asc = app.bundleIDs.lazy.compactMap({ byBundleID[$0] }).first {
                // Two groups of targets that are one App Store Connect app are one app.
                if let index = matched.firstIndex(where: { $0.appStoreConnect?.id == asc.id }) {
                    matched[index].bundleIDs += app.bundleIDs.filter { !matched[index].bundleIDs.contains($0) }
                    matched[index].platforms += app.platforms.filter { !matched[index].platforms.contains($0) }
                    matched[index].schemes += app.schemes
                    matched[index].icon = matched[index].icon ?? app.icon
                    continue
                }
                app.appStoreConnect = asc
                app.name = asc.name
                matched.append(app)
            } else {
                unmatched.append(app)
            }
        }
        return matched + unmatched
    }

    /// The highest version online machines report (major.minor), else the highest any machine reported (major
    /// only), else a placeholder.
    static func xcodeVersion(machines: [Machine], now: Date, notes: inout [String]) -> String {
        func highest(_ machines: [Machine]) -> [Int]? {
            machines.flatMap { $0.report?.xcodes ?? [] }
                .map { $0.version.split(separator: ".").map { Int($0) ?? 0 } }
                .filter { !$0.isEmpty }
                .max { $0.lexicographicallyPrecedes($1) }
        }
        if let version = highest(machines.filter { $0.isOnline(now: now) }) {
            return version.prefix(2).map(String.init).joined(separator: ".")
        }
        if let version = highest(machines) { return "\(version[0])" }
        notes.append("No Mac has reported its Xcode versions yet: Xcode \(placeholderXcode) is a placeholder, so set the version your Macs have.")
        return placeholderXcode
    }
}

// MARK: - Analysis

extension WorkflowDetector {
    struct Layout {
        enum Kind { case workspace, project, xcodegen }
        var kind: Kind
        /// The workspace or project path in the workflow (for XcodeGen, the project it generates).
        var container: String
        /// The directory holding it, "" at the root.
        var directory: String
        var projectYML: String?
        var pbxproj: String?
        /// Shared schemes by name, with the `.xcscheme` path.
        var sharedSchemes: [(name: String, path: String)]
        /// Every workspace and project outside the ignored directories.
        var containers: [String] = []
    }

    struct Target {
        var name: String
        /// XcodeGen `type` or the pbxproj product type (without `com.apple.product-type.`).
        var type: String?
        /// Every platform the target builds for. Empty when none could be worked out.
        var platforms: [Platform] = []
        var sources: [String] = []
        var iconName: String?
        var hasScheme = false
        /// The target's own DEVELOPMENT_TEAM.
        var team: String?
        /// PRODUCT_BUNDLE_IDENTIFIER with the references the file resolves; nil when it has others.
        var bundleID: String?
        /// The target's own Release build settings and its xcconfig: a path relative to project.yml for XcodeGen, a
        /// file name or path relative to a folder for a pbxproj.
        var settings: [String: String] = [:]
        var configFile: String?
        var isApplication: Bool? { type.map { $0.hasPrefix("application") } }
        /// A unit or UI test bundle.
        var isTests: Bool { type.map { $0.contains("unit-test") || $0.contains("ui-testing") } ?? false }
    }

    struct XcodeGenSpec {
        var name: String?
        var team: String?
        var targets: [Target]
        /// Declared schemes and their first build target.
        var schemes: [(name: String, target: String?)]
        /// Declared schemes, and targets with a generated scheme, that list test targets.
        var schemesWithTests: Set<String> = []
        var projectSettings: [String: String] = [:]
        /// The Release xcconfig, relative to project.yml.
        var projectConfigFile: String?
        /// Files `include:` names, which are not followed.
        var includes: [String] = []
    }

    struct PBXInfo {
        var targets: [Target]
        var team: String?
        /// The project's Release build settings and xcconfig file name, under every target's.
        var projectSettings: [String: String] = [:]
        var projectConfigFile: String?
    }

    struct Analysis {
        var layout: Layout
        var wanted: [String] = []
        var notes: [String] = []
        var schemes: [DetectedScheme] = []
        var actions: [WorkflowAction] = []
        var team: String?
        var tools: [String] = []
        var icon: DetectedIcon?
        var apps: [DetectedApp] = []

        /// Every workspace and project, the chosen one first.
        var projects: [String] {
            [layout.container] + layout.containers.filter { $0 != layout.container }.sorted()
        }

        init(tree: RepositoryTree, files: [String: String]) throws(WorkflowDetectionError) {
            let paths = tree.paths.filter(WorkflowDetector.isUsable)
            let pathSet = Set(paths)
            layout = try WorkflowDetector.layout(paths: paths)
            let directory = layout.directory
            func inDirectory(_ name: String) -> String { directory.isEmpty ? name : "\(directory)/\(name)" }

            // Files every layout may want.
            var wanted: [String] = []
            if let projectYML = layout.projectYML { wanted.append(projectYML) }
            if let pbxproj = layout.pbxproj { wanted.append(pbxproj) }
            let ciScripts = WorkflowDetector.ciScriptNames.map { inDirectory("ci_scripts/\($0)") }.filter(pathSet.contains)
            wanted += ciScripts

            var spec = layout.projectYML.flatMap { files[$0] }.flatMap(WorkflowDetector.parseXcodeGen)
            var pbx = layout.pbxproj.flatMap { files[$0] }.flatMap(WorkflowDetector.parsePBXProj)
            if let path = layout.projectYML, files[path] != nil, spec == nil {
                notes.append("\(path) could not be read as YAML, so targets and schemes are guesses.")
            }
            if let path = layout.pbxproj, files[path] != nil, pbx == nil {
                notes.append("\(path) could not be parsed, so targets and schemes are guesses.")
            }
            if let includes = spec?.includes, !includes.isEmpty {
                notes.append(
                    "project.yml includes \(includes.joined(separator: ", ")), which Hangar does not read: targets defined there are missing.")
            }
            if layout.kind == .xcodegen {
                layout.container = inDirectory("\(spec?.name ?? "App").xcodeproj")
            }
            // Bundle IDs that come from xcconfig files: fetch those of the app targets (and their #includes).
            var configWants: [String] = []
            func config(_ file: String?, exact: Bool) -> [String: String] {
                guard let file else { return [:] }
                let path = exact ? inDirectory(file) : WorkflowDetector.xcconfigPath(named: file, paths: paths, near: directory)
                guard let path else { return [:] }
                let (settings, missing) = WorkflowDetector.xcconfig(at: path, files: files, pathSet: pathSet)
                configWants += missing
                return settings
            }
            func refine(_ targets: inout [Target], projectSettings: [String: String], projectConfig: String?, exact: Bool) {
                let projectLayer = config(projectConfig, exact: exact)
                for index in targets.indices where targets[index].isApplication == true && targets[index].bundleID == nil {
                    let target = targets[index]
                    let all = WorkflowDetector.layered([
                        projectLayer, projectSettings, config(target.configFile, exact: exact), target.settings,
                    ])
                    targets[index].bundleID = all["PRODUCT_BUNDLE_IDENTIFIER"].flatMap { WorkflowDetector.resolve($0, settings: all) }
                }
            }
            if var info = spec {
                refine(&info.targets, projectSettings: info.projectSettings, projectConfig: info.projectConfigFile, exact: true)
                spec = info
            }
            if var info = pbx {
                refine(&info.targets, projectSettings: info.projectSettings, projectConfig: info.projectConfigFile, exact: false)
                pbx = info
            }
            for path in configWants where !wanted.contains(path) && wanted.count < 12 { wanted.append(path) }
            let targets = (spec?.targets ?? []) + (pbx?.targets ?? [])
            func target(named name: String) -> Target? { targets.first { $0.name == name } }

            // Schemes, each with the target it builds when known.
            var found: [(name: String, target: Target?)] = []
            var withTests = spec?.schemesWithTests ?? []
            var platformsFromSpec = false
            if !layout.sharedSchemes.isEmpty {
                var fetches = 0
                for scheme in layout.sharedSchemes {
                    if let match = target(named: scheme.name) {
                        found.append((scheme.name, match))
                    } else if let text = files[scheme.path] {
                        found.append((scheme.name, WorkflowDetector.blueprintName(text).flatMap(target(named:))))
                        if text.contains("<TestableReference") { withTests.insert(scheme.name) }
                    } else {
                        if !targets.isEmpty && fetches < WorkflowDetector.maxSchemeFetches
                            && !WorkflowDetector.looksLikeNonApp(scheme.name)
                        {
                            wanted.append(scheme.path)
                            fetches += 1
                        }
                        found.append((scheme.name, nil))
                    }
                }
            } else if let spec {
                notes.append("No shared schemes found — schemes come from project.yml.")
                if !spec.schemes.isEmpty {
                    found = spec.schemes.map { ($0.name, target(named: $0.target ?? $0.name)) }
                } else {
                    let withSchemes = spec.targets.filter(\.hasScheme)
                    let chosen = withSchemes.isEmpty ? spec.targets.filter { $0.isApplication == true } : withSchemes
                    found = chosen.map { ($0.name, $0) }
                }
            } else if let pbx {
                notes.append(
                    "No shared schemes found — these are the app targets in project.pbxproj. Share the schemes in Xcode (Manage Schemes) and commit them so xcodebuild finds them.")
                found = pbx.targets.filter { $0.isApplication == true }.map { ($0.name, $0) }
            }
            if found.isEmpty {
                let name = (layout.container as NSString).lastPathComponent
                let guess = (name as NSString).deletingPathExtension
                notes.append("No schemes found: \(guess) is a guess, so check the scheme name.")
                found = [(guess, target(named: guess))]
            }

            // Without a scheme file that says so, a test target named after the scheme or its target counts.
            let testTargetNames = Set(targets.filter(\.isTests).map(\.name))
            schemes = found.map { scheme in
                let isApplication = !WorkflowDetector.looksLikeNonApp(scheme.name) && (scheme.target?.isApplication ?? true)
                let names = [scheme.name, scheme.target?.name].compactMap { $0 }
                let hasTests = withTests.contains(scheme.name)
                    || names.contains { testTargetNames.contains("\($0)Tests") || testTargetNames.contains("\($0)UITests") }
                let platforms = scheme.target?.platforms ?? []
                return DetectedScheme(
                    name: scheme.name, platform: platforms.count == 1 ? platforms[0] : nil, isApplication: isApplication,
                    hasTests: hasTests, platforms: platforms)
            }
            if let spec {
                let specNames = Set(spec.targets.map(\.name))
                platformsFromSpec = found.contains { $0.target.map { specNames.contains($0.name) && !$0.platforms.isEmpty } ?? false }
            }
            if platformsFromSpec { notes.append("Scheme platforms guessed from project.yml.") }

            let applications = schemes.filter(\.isApplication)
            let chosen = applications.isEmpty ? schemes : applications
            actions = chosen.flatMap { (scheme: DetectedScheme) -> [WorkflowAction] in
                if scheme.platforms.isEmpty {
                    notes.append("Couldn't tell which platform \(scheme.name) builds for, so it is set to macOS.")
                    return [WorkflowAction(scheme: scheme.name, platform: .macOS, export: .appStoreConnect)]
                }
                if scheme.platforms.count > 1 {
                    notes.append(
                        "Scheme \(scheme.name) builds for \(WorkflowDetector.platformList(scheme.platforms)), so each platform is its own build.")
                }
                return scheme.platforms.map { WorkflowAction(scheme: scheme.name, platform: $0, export: .appStoreConnect) }
            }

            let primary = chosen.first.flatMap { scheme in found.first { $0.name == scheme.name }?.target }
            team = spec?.team ?? pbx?.team ?? primary?.team

            // Tools and the CI scripts.
            if layout.kind == .xcodegen { tools.append("xcodegen") }
            let scripts = ciScripts.compactMap { files[$0] }
            if scripts.contains(where: { $0.contains("brew") }) { tools.append("brew") }
            let postClone = inDirectory("ci_scripts/ci_post_clone.sh")
            let projectName = (layout.container as NSString).lastPathComponent
            if layout.kind == .xcodegen {
                if let text = files[postClone] {
                    notes.append(
                        text.lowercased().contains("xcodegen")
                            ? "\(postClone) runs XcodeGen, which generates \(projectName) before the build."
                            : "\(postClone) does not run XcodeGen: add `xcodegen generate` to it, since \(projectName) is generated from project.yml.")
                } else {
                    notes.append(
                        "Add \(postClone) that runs `xcodegen generate`: \(projectName) is generated from project.yml and is not in the repository.")
                }
            } else if ciScripts.contains(postClone) {
                notes.append("\(postClone) found: it runs before the build.")
            }

            // Apps: application targets grouped by bundle ID, each with its schemes and icon.
            var appTargets: [Target] = []
            for candidate in targets where candidate.isApplication == true {
                if let index = appTargets.firstIndex(where: { $0.name == candidate.name }) {
                    appTargets[index].bundleID = appTargets[index].bundleID ?? candidate.bundleID
                } else {
                    appTargets.append(candidate)
                }
            }
            var groups: [[Target]] = []
            for appTarget in appTargets {
                if let bundleID = appTarget.bundleID, let index = groups.firstIndex(where: { $0.contains { $0.bundleID == bundleID } }) {
                    groups[index].append(appTarget)
                } else {
                    groups.append([appTarget])
                }
            }
            var iconFetches = 0
            func icon(for target: Target?, scheme: String?) -> DetectedIcon? {
                let (icon, wants) = WorkflowDetector.icon(
                    for: target, scheme: scheme, paths: paths, pathSet: pathSet, files: files, inDirectory: inDirectory)
                if let wants, iconFetches < WorkflowDetector.maxIconFetches {
                    wanted.append(wants)
                    iconFetches += 1
                }
                return icon
            }
            self.icon = icon(for: primary, scheme: chosen.first?.name)
            var detected: [DetectedApp] = groups.map { group in
                let names = Set(group.map(\.name))
                let groupSchemes = zip(found, schemes).filter { $0.0.target.map { names.contains($0.name) } ?? false }.map(\.1)
                var platforms: [Platform] = []
                for platform in group.flatMap(\.platforms) where !platforms.contains(platform) { platforms.append(platform) }
                var bundleIDs: [String] = []
                for bundleID in group.compactMap(\.bundleID) where !bundleIDs.contains(bundleID) { bundleIDs.append(bundleID) }
                let appIcon = group.lazy.compactMap { member in
                    icon(for: member, scheme: groupSchemes.first?.name)
                }.first
                return DetectedApp(
                    name: group[0].name, bundleIDs: bundleIDs, platforms: platforms, schemes: groupSchemes, icon: appIcon)
            }
            // An app no scheme builds (a helper embedded in another app) cannot be archived on its own.
            if detected.contains(where: { !$0.schemes.isEmpty }) { detected.removeAll { $0.schemes.isEmpty } }
            if detected.isEmpty {
                detected = chosen.map { scheme in
                    DetectedApp(
                        name: scheme.name, bundleIDs: [], platforms: scheme.platform.map { [$0] } ?? [], schemes: [scheme],
                        icon: scheme.name == chosen.first?.name ? self.icon : nil)
                }
            }
            apps = detected

            // Files too big to be what they claim (a generated or vendored blob) are not fetched.
            var fetchable: [String] = []
            for path in wanted where files[path] == nil && !fetchable.contains(path) {
                if let size = tree.sizes[path], size > WorkflowDetector.maxTextBytes {
                    notes.append("\(path) is \(size / 1_048_576) MB, too big to read, so it was skipped.")
                } else {
                    fetchable.append(path)
                }
            }
            self.wanted = fetchable
            if let icon = self.icon, icon.kind == .appiconset, let size = tree.sizes[icon.path], size > WorkflowDetector.maxImageBytes {
                notes.append("The app icon \(icon.path) is \(size / 1_048_576) MB, too big to show.")
            }
        }
    }

    // MARK: Layout

    /// Outside the ignored directories and not a project's own embedded workspace.
    static func isUsable(_ path: String) -> Bool {
        !path.split(separator: "/").contains { ignoredDirectories.contains(String($0)) }
            && !path.contains(".xcodeproj/project.xcworkspace")
    }

    private static func depth(_ path: String) -> Int { path.split(separator: "/").count }

    private static func topMost(_ paths: some Sequence<String>) -> String? {
        paths.min { (depth($0), $0) < (depth($1), $1) }
    }

    private static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func layout(paths: [String]) throws(WorkflowDetectionError) -> Layout {
        var workspaces = Set<String>()
        var projects = Set<String>()
        var projectYMLs: [String] = []
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            if parts.last == "project.yml" { projectYMLs.append(path) }
            guard let index = parts.firstIndex(where: { $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".xcodeproj") }) else { continue }
            let container = parts[...index].joined(separator: "/")
            if parts[index].hasSuffix(".xcworkspace") { workspaces.insert(container) } else { projects.insert(container) }
        }
        let workspace = topMost(workspaces)
        let project = topMost(projects)
        let pathSet = Set(paths)
        var layout = try chooseLayout()
        layout.containers = Array(workspaces.union(projects))
        return layout

        func chooseLayout() throws(WorkflowDetectionError) -> Layout {
            func sharedSchemes(in containers: Set<String>) -> [(name: String, path: String)] {
                paths.compactMap { path in
                    let parts = path.split(separator: "/").map(String.init)
                    guard parts.count >= 4, parts.last!.hasSuffix(".xcscheme"), parts[parts.count - 2] == "xcschemes",
                        parts[parts.count - 3] == "xcshareddata",
                        containers.contains(parts[..<(parts.count - 3)].joined(separator: "/"))
                    else { return nil }
                    return ((parts.last! as NSString).deletingPathExtension, path)
                }
                .sorted { $0.name < $1.name }
            }

            // A workspace counts when it is no deeper than the top-most project (an example workspace in a
            // subdirectory does not win over the project at the root).
            if let workspace, project.map({ depth(workspace) <= depth($0) }) ?? true {
                let directory = parent(workspace)
                let inside = projects.filter { directory.isEmpty || $0.hasPrefix(directory + "/") }
                let pbxproj = topMost(inside).map { "\($0)/project.pbxproj" }.flatMap { pathSet.contains($0) ? $0 : nil }
                return Layout(
                    kind: .workspace, container: workspace, directory: directory,
                    projectYML: projectYML(in: directory, pathSet), pbxproj: pbxproj,
                    sharedSchemes: sharedSchemes(in: inside.union([workspace])))
            }
            if let project {
                let directory = parent(project)
                let pbxproj = "\(project)/project.pbxproj"
                return Layout(
                    kind: .project, container: project, directory: directory, projectYML: projectYML(in: directory, pathSet),
                    pbxproj: pathSet.contains(pbxproj) ? pbxproj : nil, sharedSchemes: sharedSchemes(in: [project]))
            }
            if let yml = topMost(projectYMLs) {
                return Layout(kind: .xcodegen, container: "", directory: parent(yml), projectYML: yml, pbxproj: nil, sharedSchemes: [])
            }
            throw .noProjectFound
        }
    }

    private static func projectYML(in directory: String, _ paths: Set<String>) -> String? {
        let path = directory.isEmpty ? "project.yml" : "\(directory)/project.yml"
        return paths.contains(path) ? path : nil
    }

    /// Named like tests, a framework or a library rather than an app.
    static func looksLikeNonApp(_ name: String) -> Bool {
        ["Tests", "UITests", "Kit", "Framework"].contains { name.hasSuffix($0) }
    }

    /// The target's icon, and the Contents.json to fetch first when its `.appiconset` has not been read yet.
    static func icon(
        for target: Target?, scheme: String?, paths: [String], pathSet: Set<String>, files: [String: String],
        inDirectory: (String) -> String
    ) -> (DetectedIcon?, wants: String?) {
        let iconName = target?.iconName ?? "AppIcon"
        let preferred = (target?.sources ?? []).map(inDirectory) + [target?.name, scheme].compactMap { $0 }
        var wants: String?
        if let iconSet = best(
            paths.filter { $0.hasSuffix("/\(iconName).appiconset") && $0.contains(".xcassets/") }, preferred: preferred)
        {
            let contents = "\(iconSet)/Contents.json"
            if let text = files[contents] {
                if let image = largestImage(contentsJSON: text), pathSet.contains("\(iconSet)/\(image)") {
                    return (DetectedIcon(path: "\(iconSet)/\(image)", kind: .appiconset), nil)
                }
            } else if pathSet.contains(contents) {
                wants = contents
            }
        }
        let bundles = paths.filter { $0.hasSuffix("/\(iconName).icon") || $0 == "\(iconName).icon" }
        return (best(bundles, preferred: preferred).map { DetectedIcon(path: $0, kind: .iconcomposer) }, wants)
    }

    /// The path under one of the `preferred` directories (or with a component named like one), else the top-most.
    static func best(_ candidates: [String], preferred: [String]) -> String? {
        func rank(_ path: String) -> Int {
            if let index = preferred.firstIndex(where: { !$0.isEmpty && path.hasPrefix($0 + "/") }) { return index }
            let parts = Set(path.split(separator: "/").map(String.init))
            if let index = preferred.firstIndex(where: parts.contains) { return preferred.count + index }
            return 2 * preferred.count
        }
        return candidates.min { (rank($0), depth($0), $0) < (rank($1), depth($1), $1) }
    }

    // MARK: Files

    /// The `BlueprintName` of the first build entry of an `.xcscheme`.
    static func blueprintName(_ xml: String) -> String? {
        guard let range = xml.range(of: #"BlueprintName\s*=\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        let match = xml[range]
        guard let open = match.firstIndex(of: "\"") else { return nil }
        return String(match[match.index(after: open)..<match.index(before: match.endIndex)])
    }

    /// The biggest image of an `.appiconset`'s Contents.json (pixels, then the marketing/universal/mac entries).
    static func largestImage(contentsJSON: String) -> String? {
        struct Contents: Decodable {
            struct Image: Decodable {
                var filename: String?
                var idiom: String?
                var scale: String?
                var size: String?
            }
            var images: [Image]?
        }
        guard let contents = try? JSONDecoder().decode(Contents.self, from: Data(contentsJSON.utf8)) else { return nil }
        func pixels(_ image: Contents.Image) -> Double {
            let width = Double(image.size?.split(separator: "x").first ?? "") ?? 0
            let scale = Double(image.scale?.replacingOccurrences(of: "x", with: "") ?? "") ?? 1
            return width * scale
        }
        func preference(_ image: Contents.Image) -> Int {
            ["ios-marketing", "universal", "mac"].firstIndex(of: image.idiom ?? "").map { 3 - $0 } ?? 0
        }
        return (contents.images ?? [])
            .filter { $0.filename.map { !$0.isEmpty && !$0.contains("/") } ?? false }
            .max { (pixels($0), preference($0)) < (pixels($1), preference($1)) }?
            .filename
    }

    static func platform(named name: String) -> Platform? {
        Platform(rawValue: name.lowercased())
    }

    /// Every platform named by SDK tokens (`iphoneos`, `macosx`) or platform names (`iOS`, `macOS`), in order, with
    /// simulator variants collapsed onto the same platform.
    static func platforms(from tokens: [String]) -> [Platform] {
        var found: [Platform] = []
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let platform = Self.platform(sdk: trimmed) ?? Self.platform(named: trimmed),
                !found.contains(platform)
            else { continue }
            found.append(platform)
        }
        return found
    }

    /// "iOS and macOS", "iOS, macOS and visionOS".
    static func platformList(_ platforms: [Platform]) -> String {
        let names = platforms.map(\.ciName)
        if names.count <= 1 { return names.joined() }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    static func platform(sdk: String) -> Platform? {
        let sdk = sdk.lowercased()
        if sdk.hasPrefix("iphone") { return .iOS }
        if sdk.hasPrefix("macosx") { return .macOS }
        if sdk.hasPrefix("xr") { return .visionOS }
        if sdk.hasPrefix("appletv") { return .tvOS }
        if sdk.hasPrefix("watch") { return .watchOS }
        return nil
    }

    // MARK: XcodeGen

    static func parseXcodeGen(_ text: String) -> XcodeGenSpec? {
        guard let root = (try? Yams.compose(yaml: text))?.flatMap({ $0.mapping }) else { return nil }
        /// The scalar settings of a `settings:` map: `base`, then the keys set directly.
        func settings(_ node: Node?) -> [String: String] {
            guard let map = node?.mapping else { return [:] }
            var result: [String: String] = [:]
            for (key, value) in map["base"]?.mapping ?? [:] {
                if let key = key.string, let value = value.string { result[key] = value }
            }
            for (key, value) in map {
                guard let key = key.string, !["base", "configs", "groups"].contains(key), let value = value.string else { continue }
                result[key] = value
            }
            return result
        }
        let projectSettings = settings(root["settings"])
        let bundleIDPrefix = root["options"]?.mapping?["bundleIdPrefix"]?.string
        func releaseConfigFile(_ node: Node?) -> String? {
            guard let map = node?.mapping else { return nil }
            return map["Release"]?.string ?? map.first { $0.key.string?.lowercased().contains("release") == true }?.value.string
        }
        var targets: [Target] = []
        for (key, value) in root["targets"]?.mapping ?? [:] {
            guard let name = key.string, let map = value.mapping else { continue }
            var tokens: [String] = []
            if let platformNode = map["platform"] {
                if let name = platformNode.string { tokens.append(name) }
                for item in platformNode.sequence ?? [] {
                    if let name = item.string { tokens.append(name) }
                }
            }
            if let destinations = map["supportedDestinations"]?.sequence {
                for item in destinations {
                    if let name = item.string { tokens.append(name) }
                }
            }
            let foundPlatforms = Self.platforms(from: tokens)
            var sources: [String] = []
            if let node = map["sources"] {
                if let single = node.string { sources = [single] }
                for item in node.sequence ?? [] {
                    if let path = item.string ?? item.mapping?["path"]?.string { sources.append(path) }
                }
            }
            let targetSettings = settings(map["settings"])
            let defaults = ["TARGET_NAME": name, "PRODUCT_NAME": map["productName"]?.string ?? name]
            let all = layered([defaults, projectSettings, targetSettings])
            let bundleID = all["PRODUCT_BUNDLE_IDENTIFIER"].map { resolve($0, settings: all) }
                ?? bundleIDPrefix.map { resolve("\($0).\(name)", settings: all) }
            var target = Target(
                name: name, type: map["type"]?.string,
                platforms: foundPlatforms, sources: sources.map(Self.trimmedPath),
                iconName: all["ASSETCATALOG_COMPILER_APPICON_NAME"], hasScheme: map["scheme"] != nil)
            target.team = all["DEVELOPMENT_TEAM"]
            target.bundleID = bundleID ?? nil
            target.settings = defaults.merging(targetSettings) { $1 }
            target.configFile = releaseConfigFile(map["configFiles"])
            targets.append(target)
        }
        var schemes: [(name: String, target: String?)] = []
        var schemesWithTests: Set<String> = []
        for (key, value) in root["schemes"]?.mapping ?? [:] {
            guard let name = key.string else { continue }
            let buildTargets = value.mapping?["build"]?.mapping?["targets"]
            let first = buildTargets?.mapping?.first?.key.string ?? buildTargets?.sequence?.first?.string
            schemes.append((name, first))
            let testTargets = value.mapping?["test"]?.mapping?["targets"]
            if !(testTargets?.sequence ?? []).isEmpty || !(testTargets?.mapping ?? [:]).isEmpty { schemesWithTests.insert(name) }
        }
        for (key, value) in root["targets"]?.mapping ?? [:] {
            guard let name = key.string, let testTargets = value.mapping?["scheme"]?.mapping?["testTargets"]?.sequence else { continue }
            if !testTargets.isEmpty { schemesWithTests.insert(name) }
        }
        return XcodeGenSpec(
            name: root["name"]?.string, team: projectSettings["DEVELOPMENT_TEAM"], targets: targets, schemes: schemes,
            schemesWithTests: schemesWithTests,
            projectSettings: projectSettings, projectConfigFile: releaseConfigFile(root["configFiles"]),
            includes: (root["include"]?.sequence ?? root["include"].map { [$0] } ?? []).compactMap { $0.string ?? $0.mapping?["path"]?.string })
    }

    /// `value` with its `$(NAME)`, `$(NAME:modifier)`, `${NAME}` and `$NAME` references replaced from `settings`;
    /// nil when one cannot be (it comes from the environment, say). `$(inherited)` and `$()` are empty.
    static func resolve(_ value: String, settings: [String: String], depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        func isIdentifier(_ character: Character) -> Bool { character.isASCII && (character.isLetter || character.isNumber || character == "_") }
        var result = ""
        var index = value.startIndex
        while let dollar = value[index...].firstIndex(of: "$") {
            result += value[index..<dollar]
            let next = value.index(after: dollar)
            var reference: [String]
            if next < value.endIndex, value[next] == "(" || value[next] == "{" {
                let close: Character = value[next] == "(" ? ")" : "}"
                guard let end = value[next...].firstIndex(of: close) else { return nil }
                reference = value[value.index(after: next)..<end].split(separator: ":", maxSplits: 1).map(String.init)
                if reference.isEmpty { reference = [""] }
                index = value.index(after: end)
            } else if next < value.endIndex, isIdentifier(value[next]) {
                let end = value[next...].firstIndex { !isIdentifier($0) } ?? value.endIndex
                reference = [String(value[next..<end])]
                index = end
            } else {
                result += "$"
                index = next
                continue
            }
            let name = reference[0]
            var replacement: String
            if name.isEmpty || name == "inherited" {
                replacement = ""
            } else {
                guard let raw = settings[name], let resolved = resolve(raw, settings: settings, depth: depth + 1) else { return nil }
                replacement = resolved
            }
            if reference.count == 2 {
                for modifier in reference[1].split(separator: ",") {
                    switch modifier {
                    case "rfc1034identifier":
                        replacement = String(replacement.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "-" })
                    case "c99extidentifier":
                        replacement = String(replacement.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
                    case "lower": replacement = replacement.lowercased()
                    case "upper": replacement = replacement.uppercased()
                    default: return nil
                    }
                }
            }
            result += replacement
        }
        result += value[index...]
        return result.isEmpty ? nil : result
    }

    /// Build-setting layers merged lowest first, as Xcode does: a value that names its own setting (or
    /// `$(inherited)`) gets the lower layers' value there.
    static func layered(_ layers: [[String: String]]) -> [String: String] {
        var result: [String: String] = [:]
        for layer in layers {
            for (key, value) in layer {
                guard let lower = result[key] else {
                    result[key] = value
                    continue
                }
                var merged = value.replacingOccurrences(of: "$(inherited)", with: lower)
                    .replacingOccurrences(of: "${inherited}", with: lower)
                    .replacingOccurrences(of: "$(\(key))", with: lower)
                    .replacingOccurrences(of: "${\(key)}", with: lower)
                if merged == "$\(key)" { merged = lower }
                result[key] = merged
            }
        }
        return result
    }

    private static func trimmedPath(_ path: String) -> String {
        var path = path
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: xcconfig

    /// The repository path of the xcconfig file `name` (a pbxproj file reference keeps only its name): the one under
    /// the project's directory, else the top-most.
    static func xcconfigPath(named name: String, paths: [String], near directory: String) -> String? {
        let matches = paths.filter { $0 == name || $0.hasSuffix("/\(name)") }  // `name` may be `Folder/File.xcconfig`
        return best(matches, preferred: directory.isEmpty ? [] : [directory])
    }

    /// The settings of the xcconfig at `path` and the files it includes (included ones first, so the file's own
    /// win), and the files still to fetch. Conditional settings (`KEY[sdk=…]`) are skipped.
    static func xcconfig(at path: String, files: [String: String], pathSet: Set<String>, depth: Int = 0) -> ([String: String], missing: [String]) {
        guard depth < 4 else { return ([:], []) }
        guard let text = files[path] else { return ([:], pathSet.contains(path) ? [path] : []) }
        var settings: [String: String] = [:]
        var missing: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#include") {
                guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else { continue }
                let included = normalized(parent(path), String(line[line.index(after: open)..<close]))
                let (nested, nestedMissing) = xcconfig(at: included, files: files, pathSet: pathSet, depth: depth + 1)
                settings.merge(nested) { $1 }
                missing += nestedMissing
                continue
            }
            guard !line.hasPrefix("//"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let comment = value.range(of: " //") { value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces) }
            if value.hasSuffix(";") { value.removeLast() }
            settings[key] = value
        }
        return (settings, missing)
    }

    /// `relative` joined to `directory`, with `.` and `..` resolved.
    private static func normalized(_ directory: String, _ relative: String) -> String {
        var parts = relative.hasPrefix("/") ? [] : directory.split(separator: "/").map(String.init)
        for part in relative.split(separator: "/").map(String.init) {
            if part == "." || part.isEmpty { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(part) }
        }
        return parts.joined(separator: "/")
    }

    // MARK: project.pbxproj

    static func parsePBXProj(_ text: String) -> PBXInfo? {
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any],
            let objects = plist["objects"] as? [String: Any]
        else { return nil }
        func object(_ id: Any?) -> [String: Any]? { (id as? String).flatMap { objects[$0] as? [String: Any] } }
        func buildSettings(list: Any?) -> [[String: Any]] {
            let ids = object(list)?["buildConfigurations"] as? [String] ?? []
            // Release first: what an archive uses.
            let configurations = ids.compactMap { object($0) }
                .sorted { ($0["name"] as? String == "Release" ? 0 : 1) < ($1["name"] as? String == "Release" ? 0 : 1) }
            return configurations.compactMap { $0["buildSettings"] as? [String: Any] }
        }
        let project = object(plist["rootObject"])
        let projectSettings = buildSettings(list: project?["buildConfigurationList"])
        /// The string settings of the first (Release) configuration, the target's over the project's.
        func flattened(_ settings: [[String: Any]]) -> [String: String] {
            var result: [String: String] = [:]
            for layer in [projectSettings.first, settings.first].compactMap({ $0 }) {
                for (key, value) in layer {
                    if let text = value as? String { result[key] = text }
                }
            }
            return result
        }
        func setting(_ key: String, _ settings: [[String: Any]]) -> String? {
            (settings + projectSettings).lazy.compactMap { $0[key] as? String }.first { !$0.isEmpty }
        }
        /// The file name of the Release configuration's xcconfig (`baseConfigurationReference`).
        func configFile(list: Any?) -> String? {
            let ids = object(list)?["buildConfigurations"] as? [String] ?? []
            let configurations = ids.compactMap { object($0) }
            let release = configurations.first { $0["name"] as? String == "Release" } ?? configurations.first
            if let relative = release?["baseConfigurationReferenceRelativePath"] as? String { return relative }
            return (object(release?["baseConfigurationReference"])?["path"] as? String).map { ($0 as NSString).lastPathComponent }
        }
        func strings(_ layer: [String: Any]?) -> [String: String] {
            (layer ?? [:]).compactMapValues { $0 as? String }
        }

        let ids = (project?["targets"] as? [String]) ?? objects.keys.sorted()
        var targets: [Target] = []
        for id in ids {
            guard let target = object(id), target["isa"] as? String == "PBXNativeTarget", let name = target["name"] as? String
            else { continue }
            let settings = buildSettings(list: target["buildConfigurationList"])
            var tokens: [String] = []
            if let supported = setting("SUPPORTED_PLATFORMS", settings) {
                tokens += supported.split(whereSeparator: \.isWhitespace).map(String.init)
            }
            if let sdk = setting("SDKROOT", settings) { tokens.append(sdk) }
            let foundPlatforms = Self.platforms(from: tokens)
            let type = (target["productType"] as? String).map { $0.replacingOccurrences(of: "com.apple.product-type.", with: "") }
            var entry = Target(
                name: name, type: type,
                platforms: foundPlatforms, iconName: setting("ASSETCATALOG_COMPILER_APPICON_NAME", settings))
            entry.team = setting("DEVELOPMENT_TEAM", settings)
            entry.settings = strings(settings.first)
            entry.settings["TARGET_NAME"] = entry.settings["TARGET_NAME"] ?? name
            entry.settings["PRODUCT_NAME"] = entry.settings["PRODUCT_NAME"] ?? target["productName"] as? String ?? name
            entry.configFile = configFile(list: target["buildConfigurationList"])
            var all = flattened(settings)
            all["TARGET_NAME"] = all["TARGET_NAME"] ?? name
            if all["PRODUCT_NAME"] == nil { all["PRODUCT_NAME"] = target["productName"] as? String ?? name }
            entry.bundleID = all["PRODUCT_BUNDLE_IDENTIFIER"].flatMap { resolve($0, settings: all) }
            targets.append(entry)
        }

        // The most common team, as the brief has it: across every build configuration.
        var counts: [String: Int] = [:]
        let pattern = #"DEVELOPMENT_TEAM = "?([A-Za-z0-9]+)"?;"#
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: searchRange) {
            let match = text[range]
            let value = match.replacingOccurrences(of: "DEVELOPMENT_TEAM = ", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\";"))
            counts[value, default: 0] += 1
            searchRange = range.upperBound..<text.endIndex
        }
        let team = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        return PBXInfo(
            targets: targets, team: team, projectSettings: strings(projectSettings.first),
            projectConfigFile: configFile(list: project?["buildConfigurationList"]))
    }
}
