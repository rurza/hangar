import Foundation
import HangarAppStoreConnect
import HangarCore
import Logging

/// The development profiles a VM archive's guest signs with, so that no App Store Connect key enters the guest
/// (VM builds design, *Signing*; security review 2026-11-06, C1).
///
/// For the app's own bundle IDs (its App Store Connect bundle ID and every registered one under it, `<id>.*`, of the
/// archive's platform), the server finds an active development profile of the platform's type that holds Hangar's
/// signing certificate, and creates one only when there is none. It never reads or touches a distribution profile
/// (`ASCDevelopmentProfileType` has no such case), never a bundle ID outside the app's, and logs every profile it
/// creates. What it cannot provide is listed as missing, with the reason; the optional development key then comes
/// along for the guest's `-allowProvisioningUpdates`.
///
/// Requests for the same app and profile type share one lookup, so two VM slots never create two profiles at once.
public actor DevelopmentProfileService {
    /// A profile expiring sooner than this counts as missing: a long archive must not outlive it.
    static let minimumValidity: TimeInterval = 86_400

    let credentials: @Sendable () throws -> ASCCredentials?
    let developmentKey: @Sendable () throws -> AppStoreConnectKey?
    let identity: @Sendable () throws -> SigningIdentityInfo?
    let factory: @Sendable (ASCCredentials) -> any AppStoreConnectClient
    let now: @Sendable () -> Date
    private let logger = Logger(label: "app.hangar.server.profiles")
    private var inFlight: [String: Task<JobProvisioning, Never>] = [:]

    init(
        credentials: @escaping @Sendable () throws -> ASCCredentials?,
        developmentKey: @escaping @Sendable () throws -> AppStoreConnectKey?,
        identity: @escaping @Sendable () throws -> SigningIdentityInfo?,
        factory: @escaping @Sendable (ASCCredentials) -> any AppStoreConnectClient, now: @escaping @Sendable () -> Date
    ) {
        self.credentials = credentials
        self.developmentKey = developmentKey
        self.identity = identity
        self.factory = factory
        self.now = now
    }

    /// The profile type a platform's archive signs with.
    static func profileType(_ platform: Platform) -> ASCDevelopmentProfileType {
        switch platform {
        case .macOS: .macOS
        case .tvOS: .tvOS
        case .iOS, .visionOS, .watchOS: .iOS
        }
    }

    /// Whether `identifier` is the app's: its own bundle ID or one under it.
    static func isOwn(_ identifier: String, root: String) -> Bool {
        identifier == root || identifier.hasPrefix(root + ".")
    }

    /// What the guest of `app`'s archive for `platform` signs with. Never throws: what fails becomes `missing`.
    public func provision(app: App, platform: Platform, useServerIdentity: Bool) async -> JobProvisioning {
        let key = "\(app.id.uuidString)/\(Self.profileType(platform).rawValue)/\(useServerIdentity)"
        if let running = inFlight[key] { return await running.value }
        let task = Task { await self.lookUp(app: app, platform: platform, useServerIdentity: useServerIdentity) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func lookUp(app: App, platform: Platform, useServerIdentity: Bool) async -> JobProvisioning {
        var result: JobProvisioning
        do {
            result = try await profiles(app: app, platform: platform, useServerIdentity: useServerIdentity)
        } catch {
            result = JobProvisioning(missing: [
                MissingProfile(bundleID: app.name, reason: "App Store Connect could not be asked: \(Self.reason(error))")
            ])
        }
        if !result.missing.isEmpty {
            do {
                result.developmentKey = try developmentKey()
            } catch {
                logger.error("could not read the development key: \(error)")
            }
        }
        return result
    }

    private func profiles(app: App, platform: Platform, useServerIdentity: Bool) async throws -> JobProvisioning {
        func allMissing(_ reason: String) -> JobProvisioning {
            JobProvisioning(missing: [MissingProfile(bundleID: app.name, reason: reason)])
        }
        guard useServerIdentity else {
            return allMissing("this Mac signs VM archives with its own identity, which Hangar’s profiles do not hold")
        }
        guard let credentials = try credentials() else { return allMissing("Hangar has no App Store Connect key") }
        guard credentials.issuerID?.isEmpty == false else {
            return allMissing("Hangar’s App Store Connect key is an individual key, which cannot read or create profiles")
        }
        guard let identity = try identity() else { return allMissing("Hangar has no signing certificate (Settings › Signing)") }
        let client = factory(credentials)
        let certificateID: String
        if let stored = identity.ascCertificateID {
            certificateID = stored
        } else if let found = try await client.certificateID(serialNumber: identity.serialNumber) {
            certificateID = found
        } else {
            return allMissing("App Store Connect does not list Hangar’s signing certificate (serial \(identity.serialNumber))")
        }
        guard let root = try await client.app(id: app.appStoreConnectAppID)?.bundleID, !root.isEmpty else {
            return allMissing("App Store Connect has no app \(app.appStoreConnectAppID) for \(app.name)")
        }
        let type = Self.profileType(platform)
        let bundleIDs = try await client.bundleIdentifiers()
            .filter { Self.isOwn($0.identifier, root: root) && type.bundleIDPlatforms.contains($0.platform) }
            .sorted { $0.identifier < $1.identifier }
        guard !bundleIDs.isEmpty else {
            return JobProvisioning(missing: [MissingProfile(bundleID: root, reason: "the bundle ID is not registered for this team")])
        }
        let cutoff = now().addingTimeInterval(Self.minimumValidity)
        let existing = try await client.developmentProfiles(type: type).filter {
            $0.certificateIDs.contains(certificateID) && ($0.expirationDate.map { $0 > cutoff } ?? true)
        }
        var result = JobProvisioning()
        var devices: [String]?
        for bundleID in bundleIDs {
            if let profile = existing.first(where: { $0.bundleIDResourceID == bundleID.id }) {
                result.profiles.append(Self.jobProfile(profile, bundleID: bundleID.identifier))
                continue
            }
            do {
                if devices == nil { devices = try await client.enabledDeviceIDs(platform: type.devicePlatform) }
                let name = Self.profileName(bundleID.identifier, on: now())
                let created = try await client.createDevelopmentProfile(
                    name: name, type: type, bundleIDResourceID: bundleID.id, certificateIDs: [certificateID],
                    deviceIDs: devices ?? [])
                let note = "created development profile “\(created.name)” (\(created.uuid)) for \(bundleID.identifier) with Hangar’s signing certificate"
                logger.notice("\(note)", metadata: ["app": "\(app.slug)"])
                result.notes.append(note)
                result.profiles.append(Self.jobProfile(created, bundleID: bundleID.identifier))
            } catch {
                result.missing.append(MissingProfile(
                    bundleID: bundleID.identifier, reason: "could not create its development profile: \(Self.reason(error))"))
            }
        }
        return result
    }

    /// "Hangar Development com.acme.app 2026-11-06": profile names are unique per team, hence the date.
    static func profileName(_ identifier: String, on date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Hangar Development \(identifier) \(formatter.string(from: date))"
    }

    static func jobProfile(_ profile: ASCProfile, bundleID: String) -> JobProvisioningProfile {
        JobProvisioningProfile(
            bundleID: bundleID, name: profile.name, uuid: profile.uuid, isMac: profile.type == .macOS, content: profile.content)
    }

    private static func reason(_ error: any Error) -> String {
        switch error {
        case ASCError.http(let status, let body):
            let detail = body.split(separator: "\n").first.map { String($0.prefix(200)) } ?? ""
            return detail.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(detail)"
        default: return String(describing: error)
        }
    }
}
