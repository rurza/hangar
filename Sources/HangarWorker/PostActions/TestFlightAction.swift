import Foundation
import HangarAppStoreConnect
import HangarCore

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
public struct TestFlightAction: PostActionModule {
    private static let pollInterval = Duration.seconds(30)

    private let settings: TestFlightSettings

    public init(settings: TestFlightSettings) {
        self.settings = settings
    }

    public func run(_ context: PostActionContext) async throws -> PostActionOutput {
        // Without a team key the upload uses the Xcode account, but there must be some App Store Connect key.
        guard context.key != nil || context.appStoreConnect != nil else { throw TestFlightError.appStoreConnectNotConfigured }
        let platform = context.action.platform
        let label = "Build \(context.buildNumber) (\(platform.ciName))"

        // Fail before the irreversible upload when the later steps could not run.
        if settings.waitForProcessing, context.appStoreConnect == nil { throw TestFlightError.appStoreConnectNotConfigured }

        context.log("uploading \(label) to App Store Connect")
        _ = try await ExportStep(runner: context.runner).run(
            archivePath: context.archivePath, method: .appStoreConnect, destination: "upload",
            exportPath: context.layout.upload, jobDirectory: context.layout.jobDirectory, teamID: context.teamID,
            developerDir: context.developerDir, key: context.key, signing: .cloudManaged, environment: context.xcodebuildEnvironment,
            log: context.log)

        guard settings.waitForProcessing else {
            context.log("not waiting for processing; skipping groups, What to Test and beta review")
            return PostActionOutput(summary: "\(label) was accepted by App Store Connect; not waiting for processing")
        }
        guard let client = context.appStoreConnect else { throw TestFlightError.appStoreConnectNotConfigured }

        let build = try await waitForProcessing(client, context)
        try await addToGroups(build, client: client, context: context)
        if settings.whatToTest { try await setWhatToTest(build, client: client, context: context) }
        if settings.submitForExternalReview {
            context.log("submitting for beta review")
            try await client.submitForBetaReview(buildID: build.id)
        }

        let groups = settings.groups.isEmpty ? "none" : settings.groups.joined(separator: ", ")
        return PostActionOutput(
            summary: "\(label) is \(build.processingState) in TestFlight; groups: \(groups)",
            outputs: ["testflight.buildID": build.id, "testflight.processingState": build.processingState])
    }

    /// Polls straight away, then every 30 s. A build App Store Connect does not list yet counts as processing.
    private func waitForProcessing(_ client: any AppStoreConnectClient, _ context: PostActionContext) async throws -> ASCBuild {
        let version = "\(context.buildNumber)"
        let platform = context.action.platform.appStoreConnectPlatform
        let timeout = Duration.seconds(settings.processingTimeoutMinutes * 60)
        var waited = Duration.zero
        while true {
            let builds = try await client.builds(appID: context.app.appStoreConnectAppID, version: version)
            let match = builds.first { $0.version == version && $0.platform == platform }
            context.log("TestFlight processing: \(match?.processingState ?? "not listed yet")")
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

    /// Every name is resolved before the first build is added, so a typo changes nothing.
    private func addToGroups(_ build: ASCBuild, client: any AppStoreConnectClient, context: PostActionContext) async throws {
        guard !settings.groups.isEmpty else { return }
        let available = try await client.betaGroups(appID: context.app.appStoreConnectAppID)
        let resolved = try settings.groups.map { name in
            guard let group = available.first(where: { $0.name == name }) else {
                throw TestFlightError.unknownGroup(name: name, available: available.map(\.name).sorted())
            }
            return group
        }
        for group in resolved {
            context.log("adding build to TestFlight group \(group.name)")
            try await client.addBuild(build.id, toBetaGroup: group.id)
        }
    }

    private func setWhatToTest(_ build: ASCBuild, client: any AppStoreConnectClient, context: PostActionContext) async throws {
        let project = context.projectDirectory == "." ? context.repository : "\(context.repository)/\(context.projectDirectory)"
        let directory = project + "/TestFlight"
        let prefix = "WhatToTest.", suffix = ".txt"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) && $0.count > prefix.count + suffix.count }
            .map { (locale: String($0.dropFirst(prefix.count).dropLast(suffix.count)), name: $0) }
            .sorted { $0.locale < $1.locale }
        guard !files.isEmpty else {
            context.log("no TestFlight/WhatToTest.*.txt; skipping")
            return
        }
        for file in files {
            var text = try String(contentsOfFile: directory + "/" + file.name, encoding: .utf8)
            while text.last?.isNewline == true { text.removeLast() }
            context.log("setting What to Test for \(file.locale)")
            try await client.setWhatToTest(buildID: build.id, locale: file.locale, text: text)
        }
    }
}
