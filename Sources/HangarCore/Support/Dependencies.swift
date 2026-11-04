import Dependencies

private enum ProcessRunnerKey: DependencyKey {
    static let liveValue: any ProcessRunner = LiveProcessRunner()
    static let testValue: any ProcessRunner = RecordingProcessRunner()
}

extension DependencyValues {
    public var processRunner: any ProcessRunner {
        get { self[ProcessRunnerKey.self] }
        set { self[ProcessRunnerKey.self] = newValue }
    }
}
