import Dependencies

private enum ProcessRunnerKey: DependencyKey {
    static let liveValue: any ProcessRunner = LiveProcessRunner()
    /// A fresh recorder per access, so parallel tests never share recorded commands or scripts.
    static var testValue: any ProcessRunner { RecordingProcessRunner() }
}

extension DependencyValues {
    public var processRunner: any ProcessRunner {
        get { self[ProcessRunnerKey.self] }
        set { self[ProcessRunnerKey.self] = newValue }
    }
}
