/// `GET /apps/{id}/deploy-check?workflow=&ref=&machine=`: whether a deploy could run now, judged by the scheduler's
/// own rules per action, without reserving a number or creating a build.
public struct DeployCheck: Codable, Equatable, Sendable {
    /// Every action has a machine that can run it (perhaps after waiting for a free slot or disk space), and the
    /// workflow has no `workflowProblems`.
    public var canDeploy: Bool
    /// Actions no machine can run, with each machine's reasons.
    public var blocking: [DeployCheckAction]
    /// Actions that can run but will wait first ("busy", low disk), with each machine's reasons.
    public var warnings: [DeployCheckAction]
    /// Each machine (pinned: only that one) as the scheduler sees it now: online by the server's clock, and why it
    /// cannot take any of this workflow's actions.
    public var machines: [DeployCheckMachine]
    /// Problems in the repository or App Store Connect the build is likely to hit, found before it runs. They never
    /// block the deploy. Empty from an older server.
    public var notices: [DeployCheckNotice]
    /// Why the workflow would fail on any machine at this commit (a test action on a scheme without tests), one
    /// sentence each. They block the deploy: the server refuses it before reserving a number. Empty from an older
    /// server.
    public var workflowProblems: [String]

    public init(
        canDeploy: Bool, blocking: [DeployCheckAction], warnings: [DeployCheckAction], machines: [DeployCheckMachine],
        notices: [DeployCheckNotice] = [], workflowProblems: [String] = []
    ) {
        self.canDeploy = canDeploy
        self.blocking = blocking
        self.warnings = warnings
        self.machines = machines
        self.notices = notices
        self.workflowProblems = workflowProblems
    }

    private enum CodingKeys: String, CodingKey { case canDeploy, blocking, warnings, machines, notices, workflowProblems }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canDeploy = try container.decode(Bool.self, forKey: .canDeploy)
        blocking = try container.decode([DeployCheckAction].self, forKey: .blocking)
        warnings = try container.decode([DeployCheckAction].self, forKey: .warnings)
        machines = try container.decode([DeployCheckMachine].self, forKey: .machines)
        notices = try container.decodeIfPresent([DeployCheckNotice].self, forKey: .notices) ?? []
        workflowProblems = try container.decodeIfPresent([String].self, forKey: .workflowProblems) ?? []
    }
}

/// One pre-deploy warning: `code` for the UI (`undefined-variables`, `script-not-executable`,
/// `beta-app-description-missing`), `message` a sentence that says what to do.
public struct DeployCheckNotice: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
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
    /// Passing reasons: busy, low disk, builds paused.
    public var waits: [String]
    /// Builds are turned off on this Mac; jobs wait for it until it is resumed. False from an older server.
    public var paused: Bool

    public init(id: String, name: String, online: Bool, problems: [String], waits: [String], paused: Bool = false) {
        self.id = id
        self.name = name
        self.online = online
        self.problems = problems
        self.waits = waits
        self.paused = paused
    }

    private enum CodingKeys: String, CodingKey { case id, name, online, problems, waits, paused }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        online = try container.decode(Bool.self, forKey: .online)
        problems = try container.decode([String].self, forKey: .problems)
        waits = try container.decode([String].self, forKey: .waits)
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }
}
