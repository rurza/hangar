import Foundation

public struct NumbersReport: Codable, Equatable, Sendable {
    public var appID: UUID
    public var highestHangar: Int?
    public var next: Int
    public var highestAppStoreConnect: Int?
    public var lastXcodeCloudRun: Int?
    public var inFlight: Bool

    public init(
        appID: UUID, highestHangar: Int? = nil, next: Int, highestAppStoreConnect: Int? = nil,
        lastXcodeCloudRun: Int? = nil, inFlight: Bool
    ) {
        self.appID = appID
        self.highestHangar = highestHangar
        self.next = next
        self.highestAppStoreConnect = highestAppStoreConnect
        self.lastXcodeCloudRun = lastXcodeCloudRun
        self.inFlight = inFlight
    }
}
