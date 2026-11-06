import Foundation
import HangarAppStoreConnect
import HangarCore
import Synchronization

public enum TestFlightError: Error, Equatable, CustomStringConvertible {
    case appStoreConnectNotConfigured
    case processingFailed(state: String)
    case processingTimedOut(minutes: Int)
    case unknownGroup(name: String, available: [String])

    public var description: String {
        switch self {
        case .appStoreConnectNotConfigured:
            "App Store Connect credentials are not configured for this app"
        case .processingFailed(let state):
            "App Store Connect finished processing the build with state \(state)"
        case .processingTimedOut(let minutes):
            "The build was still processing after \(minutes) minutes"
        case .unknownGroup(let name, let available):
            "No TestFlight group named '\(name)'; available groups: \(available.isEmpty ? "none" : available.joined(separator: ", "))"
        }
    }
}

/// Uploads the archive to App Store Connect, waits for processing, then distributes it to TestFlight groups.
///
/// The step reports its stages as it goes: Upload, Processing, then Groups, What to Test and Beta review when the
/// workflow asks for them. A failed upload or processing fails the job. Once the build is processed it is in
/// TestFlight, so what goes wrong after that (a group App Store Connect refuses, What to Test, the review
/// submission) becomes a warning on the step and the job still succeeds.
public struct TestFlightAction: PostActionModule {
    private static let pollInterval = Duration.seconds(30)

    enum Stage {
        static let upload = "Upload"
        static let processing = "Processing"
        static let groups = "Groups"
        static let whatToTest = "What to Test"
        static let review = "Beta review"
    }

    private let settings: TestFlightSettings

    public init(settings: TestFlightSettings) {
        self.settings = settings
    }

    /// The stages so far, reported to the build page on each change.
    private final class Progress: Sendable {
        private let state: Mutex<[StepStage]>
        private let report: @Sendable ([StepStage]) async -> Void

        init(_ stages: [StepStage], report: @escaping @Sendable ([StepStage]) async -> Void) {
            state = Mutex(stages)
            self.report = report
        }

        var stages: [StepStage] { state.withLock { $0 } }

        func set(_ name: String, _ status: StepStatus, _ detail: String? = nil) async {
            let stages = state.withLock { stages in
                if let index = stages.firstIndex(where: { $0.name == name }) {
                    stages[index] = StepStage(name: name, status: status, detail: detail)
                }
                return stages
            }
            await report(stages)
        }
    }

    public func run(_ context: PostActionContext) async throws -> PostActionOutput {
        // Without a team key the upload uses the Xcode account, but there must be some App Store Connect key.
        guard context.key != nil || context.appStoreConnect != nil else { throw TestFlightError.appStoreConnectNotConfigured }
        let platform = context.action.platform
        let label = "Build \(context.buildNumber) (\(platform.ciName))"

        // Fail before the irreversible upload when the later steps could not run.
        if settings.waitForProcessing, context.appStoreConnect == nil { throw TestFlightError.appStoreConnectNotConfigured }

        var names = [Stage.upload, Stage.processing]
        if settings.waitForProcessing {
            if !settings.groups.isEmpty { names.append(Stage.groups) }
            if settings.whatToTest { names.append(Stage.whatToTest) }
            if settings.submitForExternalReview { names.append(Stage.review) }
        }
        let progress = Progress(names.map { StepStage(name: $0, status: .pending) }, report: context.reportStages)

        await progress.set(Stage.upload, .running)
        context.log("uploading \(label) to App Store Connect")
        do {
            _ = try await ExportStep(runner: context.runner).run(
                archivePath: context.archivePath, method: .appStoreConnect, destination: "upload",
                exportPath: context.layout.upload, jobDirectory: context.layout.jobDirectory, teamID: context.teamID,
                developerDir: context.developerDir, key: context.key, signing: .cloudManaged,
                environment: context.xcodebuildEnvironment, log: context.log)
        } catch {
            await progress.set(Stage.upload, .failed, String(describing: error))
            throw error
        }
        await progress.set(Stage.upload, .succeeded)

        guard settings.waitForProcessing else {
            context.log("not waiting for processing; skipping groups, What to Test and beta review")
            await progress.set(Stage.processing, .skipped, "Not waiting for processing")
            return PostActionOutput(
                summary: "\(label) was accepted by App Store Connect; not waiting for processing", stages: progress.stages)
        }
        guard let client = context.appStoreConnect else { throw TestFlightError.appStoreConnectNotConfigured }

        await progress.set(Stage.processing, .running)
        let build: ASCBuild
        do {
            build = try await waitForProcessing(client, context)
        } catch TestFlightError.processingTimedOut(let minutes) {
            // The upload went through; Apple is only slow. The build still turns up in TestFlight, just without what
            // needs a processed build (groups, What to Test, review).
            let reason = TestFlightError.processingTimedOut(minutes: minutes).description
            context.log("warning: \(reason); it will still appear in TestFlight, without groups, What to Test or review")
            await progress.set(Stage.processing, .warning, reason)
            return PostActionOutput(
                summary: "\(label) was uploaded; App Store Connect was still processing it after \(minutes) minutes",
                warnings: ["Processing: \(reason)"], stages: progress.stages)
        } catch {
            await progress.set(Stage.processing, .failed, Self.reason(error))
            throw error
        }
        await progress.set(Stage.processing, .succeeded, build.processingState)

        var warnings: [String] = []
        if !settings.groups.isEmpty {
            await progress.set(Stage.groups, .running)
            let outcome = await addToGroups(build, client: client, context: context)
            warnings += outcome.problems.map { "Groups: \($0)" }
            await progress.set(Stage.groups, outcome.problems.isEmpty ? .succeeded : .warning, outcome.detail)
        }
        if settings.whatToTest {
            await progress.set(Stage.whatToTest, .running)
            do {
                let detail = try await setWhatToTest(build, client: client, context: context)
                await progress.set(Stage.whatToTest, detail == nil ? .skipped : .succeeded, detail ?? "No TestFlight/WhatToTest.*.txt")
            } catch {
                let reason = Self.reason(error)
                context.log("warning: could not set What to Test: \(reason)")
                warnings.append("What to Test: \(reason)")
                await progress.set(Stage.whatToTest, .warning, reason)
            }
        }
        if settings.submitForExternalReview {
            await progress.set(Stage.review, .running)
            context.log("submitting for beta review")
            do {
                try await client.submitForBetaReview(buildID: build.id)
                await progress.set(Stage.review, .succeeded, "Submitted")
            } catch {
                let reason = Self.reason(error)
                context.log("warning: could not submit for beta review: \(reason)")
                warnings.append("Beta review: \(reason)")
                await progress.set(Stage.review, .warning, reason)
            }
        }

        let groups = settings.groups.isEmpty ? "none" : settings.groups.joined(separator: ", ")
        return PostActionOutput(
            summary: "\(label) is \(build.processingState) in TestFlight; groups: \(groups)"
                + (warnings.isEmpty ? "" : " (with \(warnings.count == 1 ? "a warning" : "\(warnings.count) warnings"))"),
            outputs: ["testflight.buildID": build.id, "testflight.processingState": build.processingState],
            warnings: warnings, stages: progress.stages)
    }

    /// App Store Connect's own words for a refusal, else the error's description.
    static func reason(_ error: any Error) -> String {
        (error as? ASCError)?.refusalDetail ?? String(describing: error)
    }

    /// Polls straight away, then every 30 s. A build App Store Connect does not list yet counts as processing, and so
    /// does a poll that fails for a passing reason (a timeout, no network, HTTP 429 or 5xx): the build is uploaded,
    /// so one lost answer must not fail the job. A refusal (another 4xx) or a reply that can't be read still throws.
    private func waitForProcessing(_ client: any AppStoreConnectClient, _ context: PostActionContext) async throws -> ASCBuild {
        let version = "\(context.buildNumber)"
        let platform = context.action.platform.appStoreConnectPlatform
        let timeout = Duration.seconds(settings.processingTimeoutMinutes * 60)
        var waited = Duration.zero
        while true {
            let builds: [ASCBuild]?
            do {
                builds = try await client.builds(appID: context.app.appStoreConnectAppID, version: version)
            } catch where Self.isPassing(error) {
                context.log("TestFlight processing: could not ask App Store Connect (\(Self.reason(error))); asking again")
                builds = nil
            }
            let match = builds?.first { $0.version == version && $0.platform == platform }
            if builds != nil { context.log("TestFlight processing: \(match?.processingState ?? "not listed yet")") }
            if let match {
                switch match.processingState {
                case "VALID": return match
                case "FAILED", "INVALID": throw TestFlightError.processingFailed(state: match.processingState)
                default: break
                }
            }
            if waited >= timeout { throw TestFlightError.processingTimedOut(minutes: settings.processingTimeoutMinutes) }
            try await context.clock.sleep(for: Self.pollInterval)
            waited += Self.pollInterval
        }
    }

    /// Whether `error` is worth asking again: the network, or App Store Connect busy or failing on its side.
    static func isPassing(_ error: any Error) -> Bool {
        if error is URLError { return true }
        if case .http(let status, _) = error as? ASCError { return status == 429 || status >= 500 }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    /// What happened to the groups: a line for the stage and the problems, one sentence each.
    struct GroupsOutcome: Equatable {
        var detail: String
        var problems: [String]
    }

    /// Adds the build to each named group, one at a time, and carries on past a refusal. A group that gets every
    /// build automatically is left alone: App Store Connect refuses to assign one by hand (HTTP 422).
    private func addToGroups(_ build: ASCBuild, client: any AppStoreConnectClient, context: PostActionContext) async -> GroupsOutcome {
        let available: [ASCBetaGroup]
        do {
            available = try await client.betaGroups(appID: context.app.appStoreConnectAppID)
        } catch {
            let reason = Self.reason(error)
            context.log("warning: could not list the TestFlight groups: \(reason)")
            return GroupsOutcome(detail: reason, problems: ["could not list the TestFlight groups: \(reason)"])
        }
        var added: [String] = []
        var automatic: [String] = []
        var problems: [String] = []
        for name in settings.groups {
            guard let group = available.first(where: { $0.name == name }) else {
                let problem = TestFlightError.unknownGroup(name: name, available: available.map(\.name).sorted()).description
                context.log("warning: \(problem)")
                problems.append(problem)
                continue
            }
            if group.receivesEveryBuild {
                context.log("TestFlight group \(group.name) receives every build automatically; not adding it")
                automatic.append(group.name)
                continue
            }
            context.log("adding build to TestFlight group \(group.name)")
            do {
                try await client.addBuild(build.id, toBetaGroup: group.id)
                added.append(group.name)
            } catch {
                let reason = Self.reason(error)
                context.log("warning: could not add the build to \(group.name): \(reason)")
                problems.append("could not add the build to \(group.name): \(reason)")
            }
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append("Added to \(added.joined(separator: ", "))") }
        if !automatic.isEmpty {
            parts.append("\(automatic.joined(separator: ", ")) \(automatic.count == 1 ? "gets" : "get") every build automatically")
        }
        parts += problems
        return GroupsOutcome(detail: parts.joined(separator: "; "), problems: problems)
    }

    /// Returns the locales it set, as words; nil when the repository has no What to Test files.
    private func setWhatToTest(_ build: ASCBuild, client: any AppStoreConnectClient, context: PostActionContext) async throws -> String? {
        let project = context.projectDirectory == "." ? context.repository : "\(context.repository)/\(context.projectDirectory)"
        let directory = project + "/TestFlight"
        let prefix = "WhatToTest.", suffix = ".txt"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) && $0.count > prefix.count + suffix.count }
            .map { (locale: String($0.dropFirst(prefix.count).dropLast(suffix.count)), name: $0) }
            .sorted { $0.locale < $1.locale }
        guard !files.isEmpty else {
            context.log("no TestFlight/WhatToTest.*.txt; skipping")
            return nil
        }
        for file in files {
            var text = try String(contentsOfFile: directory + "/" + file.name, encoding: .utf8)
            while text.last?.isNewline == true { text.removeLast() }
            context.log("setting What to Test for \(file.locale)")
            try await client.setWhatToTest(buildID: build.id, locale: file.locale, text: text)
        }
        return "Set for \(files.map(\.locale).joined(separator: ", "))"
    }
}
