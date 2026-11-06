import Foundation

/// How much disk Hangar's own files take on a Mac, measured with APFS clones counted once (`DiskUsage`): what the
/// machine card and Settings show as "Hangar uses 51 GB on this Mac".
public struct HangarDiskUsage: Codable, Equatable, Sendable {
    public struct Part: Codable, Equatable, Sendable {
        /// "VM images", "Workspaces", "Build logs and artifacts", "Other".
        public var label: String
        public var gb: Double

        public init(label: String, gb: Double) {
            self.label = label
            self.gb = gb
        }
    }

    public var totalGB: Double
    /// The biggest pieces of `totalGB`, largest first; empty pieces left out.
    public var parts: [Part]
    public var measuredAt: Date

    public init(totalGB: Double, parts: [Part] = [], measuredAt: Date) {
        self.totalGB = totalGB
        self.parts = parts
        self.measuredAt = measuredAt
    }
}
