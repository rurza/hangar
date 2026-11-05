/// `GET /apps/{id}/deploy-check?workflow=&ref=&machine=`: whether a deploy could run now, judged by the scheduler's
/// own rules per action, without reserving a number or creating a build.
public struct DeployCheck: Codable, Equatable, Sendable {
    /// Every action has a machine that can run it (perhaps after waiting for a free slot or disk space).
    public var canDeploy: Bool
    /// Actions no machine can run, with each machine's reasons.
    public var blocking: [DeployCheckAction]
    /// Actions that can run but will wait first ("busy", low disk), with each machine's reasons.
    public var warnings: [DeployCheckAction]
    /// Each machine (pinned: only that one) as the scheduler sees it now: online by the server's clock, and why it
    /// cannot take any of this workflow's actions.
    public var machines: [DeployCheckMachine]

    public init(canDeploy: Bool, blocking: [DeployCheckAction], warnings: [DeployCheckAction], machines: [DeployCheckMachine]) {
        self.canDeploy = canDeploy
        self.blocking = blocking
        self.warnings = warnings
        self.machines = machines
    }
}

public struct DeployCheckAction: Codable, Equatable, Sendable {
    /// "Archive – macOS · Legilo", "Test – iOS · LegiloTests".
    public var action: String
    /// Machine name → reasons it cannot take this action now.
    public var reasons: [String: [String]]

    public init(action: String, reasons: [String: [String]]) {
        self.action = action
        self.reasons = reasons
    }
}

public struct DeployCheckMachine: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var online: Bool
    /// What keeps it from some action of the workflow for good (not busy or low disk); empty when it can run them all.
    public var problems: [String]
    /// Passing reasons: busy, low disk.
    public var waits: [String]

    public init(id: String, name: String, online: Bool, problems: [String], waits: [String]) {
        self.id = id
        self.name = name
        self.online = online
        self.problems = problems
        self.waits = waits
    }
}
