import Foundation

public struct ServerConfiguration: Sendable {
    /// The address to bind: the Tailscale interface in production.
    public var host: String
    public var port: Int
    /// Holds `hangar.sqlite`, `master.key` and `jobs/<jobID>/`.
    public var dataDirectory: String
    /// Job logs and artifacts of builds finished longer ago than this are deleted.
    public var retentionDays: Int
    /// Machines with less free disk get no new jobs.
    public var minFreeDiskGB: Double
    /// A job running this long that its machine's heartbeat no longer lists fails: the worker lost track of it
    /// (it restarted, or its finish never arrived). The grace covers a heartbeat sent just before the job started.
    public var untrackedJobGrace: TimeInterval

    public init(
        host: String, port: Int = 8787, dataDirectory: String, retentionDays: Int = 30, minFreeDiskGB: Double = 20,
        untrackedJobGrace: TimeInterval = 60
    ) {
        self.host = host
        self.port = port
        self.dataDirectory = dataDirectory
        self.retentionDays = retentionDays
        self.minFreeDiskGB = minFreeDiskGB
        self.untrackedJobGrace = untrackedJobGrace
    }

    var jobsDirectory: URL { URL(fileURLWithPath: dataDirectory).appendingPathComponent("jobs") }
    var masterKeyPath: String { URL(fileURLWithPath: dataDirectory).appendingPathComponent("master.key").path }
}
