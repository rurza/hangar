import Foundation
import HangarCore

/// One available simulator from `xcrun simctl list devices available --json`.
public struct SimulatorDevice: Equatable, Sendable {
    public var udid: String
    public var name: String
    public var deviceTypeIdentifier: String
    public var platform: Platform
    /// The runtime's version components, e.g. [27, 2].
    public var runtimeVersion: [Int]

    /// "iOS 27.2".
    public var runtime: String { "\(platform.ciName) \(runtimeVersion.map(String.init).joined(separator: "."))" }

    /// The device type's last identifier component, e.g. "iPhone-17-Pro".
    var deviceType: String {
        deviceTypeIdentifier.split(separator: ".").last.map(String.init) ?? deviceTypeIdentifier
    }

    /// The first number in the device type ("iPhone-17-Pro" → 17), standing in for its generation; -1 without one.
    var generation: Int {
        deviceType.firstMatch(of: /\d+/).flatMap { Int($0.output) } ?? -1
    }

    public var testDestination: TestDestination {
        TestDestination(
            xcodebuildDestination: "platform=\(platform.ciName) Simulator,id=\(udid)", deviceType: name, runtime: runtime)
    }
}

/// Reads simulator lists and picks a test destination from them. The JSON is read leniently: entries that do not look
/// like an available device of a known platform are ignored.
public enum SimulatorCatalog {
    public static let listArguments = ["simctl", "list", "devices", "available", "--json"]

    /// Like `list`, with nothing for output that is not a simulator list.
    public static func devices(fromJSON data: Data) -> [SimulatorDevice] {
        list(fromJSON: data) ?? []
    }

    /// The available devices, or nil when `data` holds no `{"devices": {...}}` object (lines around it are skipped).
    public static func list(fromJSON data: Data) -> [SimulatorDevice]? {
        guard let root = JSONText.object(in: data), let byRuntime = root["devices"] as? [String: Any] else { return nil }
        var devices: [SimulatorDevice] = []
        for (runtimeID, list) in byRuntime {
            guard let (platform, version) = runtime(runtimeID), let list = list as? [[String: Any]] else { continue }
            for entry in list {
                guard (entry["isAvailable"] as? Bool) != false, let udid = entry["udid"] as? String,
                    let name = entry["name"] as? String
                else { continue }
                devices.append(SimulatorDevice(
                    udid: udid, name: name, deviceTypeIdentifier: entry["deviceTypeIdentifier"] as? String ?? "",
                    platform: platform, runtimeVersion: version))
            }
        }
        return devices.sorted { ($0.runtime, $0.name, $0.udid) < ($1.runtime, $1.name, $1.udid) }
    }

    /// "iOS 27.2", "visionOS 27.1"…: each runtime with at least one device, sorted.
    public static func runtimeNames(_ devices: [SimulatorDevice]) -> [String] {
        Array(Set(devices.map(\.runtime))).sorted()
    }

    /// For `destination` nil, the newest runtime of `platform` and on it the newest device of the platform's main
    /// family (iPhone, Apple Vision, Apple TV, Apple Watch), or any device when the family has none. For a name, the
    /// device with that name or device type (case-insensitive) on the newest runtime that has it.
    public static func select(platform: Platform, destination: String?, from devices: [SimulatorDevice]) -> SimulatorDevice? {
        let candidates = devices.filter { $0.platform == platform }
        if let destination {
            let wanted = destination.lowercased()
            return candidates
                .filter { $0.name.lowercased() == wanted || $0.deviceType.replacingOccurrences(of: "-", with: " ").lowercased() == wanted }
                .max { a, b in
                    a.runtimeVersion != b.runtimeVersion
                        ? a.runtimeVersion.lexicographicallyPrecedes(b.runtimeVersion) : a.name > b.name
                }
        }
        let family = candidates.filter { device in familyPrefix(platform).map { device.deviceType.hasPrefix($0) } ?? true }
        // Newest runtime, then newest generation; between equals the shorter name ("iPhone 17" over "iPhone 17 Pro").
        return (family.isEmpty ? candidates : family).max { a, b in
            if a.runtimeVersion != b.runtimeVersion { return a.runtimeVersion.lexicographicallyPrecedes(b.runtimeVersion) }
            if a.generation != b.generation { return a.generation < b.generation }
            if a.name.count != b.name.count { return a.name.count > b.name.count }
            return a.name > b.name
        }
    }

    private static func familyPrefix(_ platform: Platform) -> String? {
        switch platform {
        case .iOS: "iPhone"
        case .visionOS: "Apple-Vision"
        case .tvOS: "Apple-TV"
        case .watchOS: "Apple-Watch"
        case .macOS: nil
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-2` (or `…iOS-27-2-iPhone19-4`) → (.iOS, [27, 2]).
    static func runtime(_ identifier: String) -> (Platform, [Int])? {
        guard let last = identifier.split(separator: ".").last else { return nil }
        let parts = last.split(separator: "-")
        guard let first = parts.first else { return nil }
        let platform: Platform
        switch first {
        case "iOS": platform = .iOS
        case "tvOS": platform = .tvOS
        case "watchOS": platform = .watchOS
        case "xrOS", "visionOS": platform = .visionOS
        default: return nil
        }
        let version = Array(parts.dropFirst().prefix { Int($0) != nil }.compactMap { Int($0) })
        return version.isEmpty ? nil : (platform, version)
    }
}

/// Reads the JSON object a tool printed, skipping lines of other output around it (a warning on stderr that reached
/// the same stream, say).
enum JSONText {
    static func object(in data: Data) -> [String: Any]? {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return object }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
            let last = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix("}") }), first <= last
        else { return nil }
        let text = lines[first...last].joined(separator: "\n")
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
