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
    /// Host names the server answers to besides the bound host, its loopback names and `*.ts.net` (see `HostPolicy`):
    /// this Mac's names found at start-up and `--allowed-host` / `HANGAR_ALLOWED_HOSTS`.
    public var allowedHosts: [String]
    /// The `hangar-worker` binary `GET /install/hangar-worker` hands out; nil when there is none (the one-command
    /// worker install then reports `worker_binary_missing`). The executable sets it from `WorkerBinary.locate()`.
    public var workerBinaryPath: String?

    public init(
        host: String, port: Int = 8787, dataDirectory: String, retentionDays: Int = 30, minFreeDiskGB: Double = 20,
        untrackedJobGrace: TimeInterval = 60, allowedHosts: [String] = [], workerBinaryPath: String? = nil
    ) {
        self.host = host
        self.port = port
        self.dataDirectory = dataDirectory
        self.retentionDays = retentionDays
        self.minFreeDiskGB = minFreeDiskGB
        self.untrackedJobGrace = untrackedJobGrace
        self.allowedHosts = allowedHosts
        self.workerBinaryPath = workerBinaryPath
    }

    /// The Host values the server answers.
    public var hostPolicy: HostPolicy { HostPolicy(boundHost: host, extraNames: allowedHosts) }

    var jobsDirectory: URL { URL(fileURLWithPath: dataDirectory).appendingPathComponent("jobs") }
    var masterKeyPath: String { URL(fileURLWithPath: dataDirectory).appendingPathComponent("master.key").path }
}

extension ServerConfiguration {
    /// Creates the data directory, or tightens an existing one, to mode 0700. It holds the database, the master key
    /// that opens every secret, job logs and signed builds; with the default umask a directory outside
    /// `~/Library` (`--data-dir`, `HANGAR_DATA_DIR`) would leave them readable by every account on the Mac.
    public static func prepareDataDirectory(at path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // An existing directory keeps its mode on createDirectory, and a new one's is subject to the umask.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }
}
