import Foundation

/// What the first-run setup page shows: what is configured, never a secret value.
public struct SetupStatus: Codable, Equatable, Sendable {
    public var appStoreConnect: ASCKeyStatus?
    public var github: GitHubStatus?
    public var machines: Int
    public var apps: Int
    /// A machine named after this Mac's local host name is enrolled.
    public var localWorker: Bool
    /// This Mac's local host name (`scutil --get LocalHostName`), the name "Use This Mac for Builds" enrolls it
    /// as; nil when it cannot be read.
    public var localHostName: String?
    /// The server has a `hangar-worker` to install (see `SettingsStatus.workerInstallAvailable`).
    public var workerInstallAvailable: Bool
    /// The request comes from the server's own Mac: only then are its keys, its gh login and "Use This Mac"
    /// offered.
    public var viewerIsLocal: Bool
    /// A worker already set up on this Mac (a worker configuration or a loaded launchd agent), whether or not
    /// Hangar knows its machine; "Use This Mac" never replaces it. Nil for a remote viewer.
    public var installedWorker: InstalledWorker?

    public init(
        appStoreConnect: ASCKeyStatus?, github: GitHubStatus?, machines: Int, apps: Int, localWorker: Bool,
        localHostName: String? = nil, workerInstallAvailable: Bool = false, viewerIsLocal: Bool = false,
        installedWorker: InstalledWorker? = nil
    ) {
        self.appStoreConnect = appStoreConnect
        self.github = github
        self.machines = machines
        self.apps = apps
        self.localWorker = localWorker
        self.localHostName = localHostName
        self.workerInstallAvailable = workerInstallAvailable
        self.viewerIsLocal = viewerIsLocal
        self.installedWorker = installedWorker
    }
}

/// A worker found on the server's Mac: the server its configuration names and whether its agent is loaded.
public struct InstalledWorker: Codable, Equatable, Sendable {
    /// From the worker configuration; nil when there is none or it cannot be read.
    public var serverURL: String?
    /// `app.hangar.worker` is loaded in this user's launchd session.
    public var agentLoaded: Bool

    public init(serverURL: String?, agentLoaded: Bool) {
        self.serverURL = serverURL
        self.agentLoaded = agentLoaded
    }
}

/// The configured GitHub token: whose it is (nil when GitHub could not be asked) and where it came from.
public struct GitHubStatus: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Pasted in Hangar.
        case token
        /// Copied from the GitHub CLI's login (`gh auth token`).
        case gh
    }

    public var login: String?
    public var source: Source

    public init(login: String?, source: Source) {
        self.login = login
        self.source = source
    }
}

/// An App Store Connect API key file found on the server's Mac. Only its location and key ID, never its contents.
public struct FoundASCKey: Codable, Equatable, Sendable {
    public var keyID: String
    public var path: String
    /// `path` with the home directory shortened to `~`.
    public var displayPath: String
    public var modifiedAt: Date

    public init(keyID: String, path: String, displayPath: String, modifiedAt: Date) {
        self.keyID = keyID
        self.path = path
        self.displayPath = displayPath
        self.modifiedAt = modifiedAt
    }
}

/// `POST /setup/asc-keys/use`: one of the scanned keys, with the issuer ID when App Store Connect asked for it.
public struct UseASCKeyRequest: Codable, Equatable, Sendable {
    public var path: String
    public var issuerID: String?

    public init(path: String, issuerID: String? = nil) {
        self.path = path
        self.issuerID = issuerID
    }
}

/// `POST /settings/asc-key`: a key uploaded from the browser, tested before it is saved.
public struct SaveASCKeyRequest: Codable, Equatable, Sendable {
    public var keyID: String
    public var issuerID: String?
    public var privateKey: String

    public init(keyID: String, issuerID: String? = nil, privateKey: String) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKey = privateKey
    }
}

/// A key that App Store Connect accepted and Hangar saved.
public struct ASCKeyTestResult: Codable, Equatable, Sendable {
    public var kind: ASCKeyStatus.Kind
    public var keyID: String
    /// How many apps the key sees in App Store Connect.
    public var appCount: Int

    public init(kind: ASCKeyStatus.Kind, keyID: String, appCount: Int) {
        self.kind = kind
        self.keyID = keyID
        self.appCount = appCount
    }
}

/// `GET /setup/github`: the GitHub CLI's signed-in account on the server's Mac, nil when there is none.
public struct GitHubCLIStatus: Codable, Equatable, Sendable {
    public var ghLogin: String?

    public init(ghLogin: String?) { self.ghLogin = ghLogin }
}

/// `POST /settings/github-token`: a token, checked with GitHub before it is saved.
public struct SaveGitHubTokenRequest: Codable, Equatable, Sendable {
    public var token: String

    public init(token: String) { self.token = token }
}

/// The account a saved GitHub token belongs to.
public struct GitHubLoginResponse: Codable, Equatable, Sendable {
    public var login: String

    public init(login: String) { self.login = login }
}

/// "Use This Mac for Builds": the worker install running on the server's Mac, polled by the setup page.
public struct LocalWorkerInstall: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, succeeded, failed }

    public var state: State
    /// The install script's output so far (the last lines only); it never holds a token or the pairing code.
    public var lines: [String]
    /// The enrolled machine, once there is one.
    public var machine: Machine?
    /// Why it failed.
    public var message: String?

    public init(state: State, lines: [String] = [], machine: Machine? = nil, message: String? = nil) {
        self.state = state
        self.lines = lines
        self.machine = machine
        self.message = message
    }
}
