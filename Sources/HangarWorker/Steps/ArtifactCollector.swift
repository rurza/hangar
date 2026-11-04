import Foundation
import HangarCore

public enum ArtifactError: Error, Equatable, CustomStringConvertible {
    case zipFailed(name: String, exitCode: Int32)

    public var description: String {
        switch self {
        case .zipFailed(let name, let exitCode): "ditto exited with status \(exitCode) while zipping \(name)"
        }
    }
}

/// Gathers what a job leaves behind for the build page: dSYMs, the result bundle, the exported product and the
/// export's property lists. Bundles are zipped with `ditto` into `<jobDirectory>/artifacts`; files are used in place.
/// Pieces that do not exist are skipped.
public struct ArtifactCollector: Sendable {
    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner) {
        self.runner = runner
    }

    public func collect(
        layout: WorkspaceLayout, scheme: String, log: @Sendable (String) -> Void
    ) async throws -> [(name: String, url: URL)] {
        let fileManager = FileManager.default
        let staging = layout.jobDirectory + "/artifacts"
        try fileManager.createDirectory(atPath: staging, withIntermediateDirectories: true)
        var collected: [(name: String, url: URL)] = []

        func zip(_ source: String, as name: String) async throws {
            guard fileManager.fileExists(atPath: source) else { return }
            let destination = staging + "/" + name
            log("zipping \(name)")
            let outcome = try await runner.run(
                ProcessCommand(
                    executable: "/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", source, destination]),
                onLine: log)
            guard outcome.exitCode == 0 else { throw ArtifactError.zipFailed(name: name, exitCode: outcome.exitCode) }
            collected.append((name, URL(fileURLWithPath: destination)))
        }
        func file(_ name: String) {
            let path = layout.export + "/" + name
            if fileManager.fileExists(atPath: path) { collected.append((name, URL(fileURLWithPath: path))) }
        }

        try await zip(layout.archive(scheme: scheme) + "/dSYMs", as: "\(scheme)-dSYMs.zip")
        try await zip(layout.resultBundle, as: "\(scheme).xcresult.zip")
        let exported = ((try? fileManager.contentsOfDirectory(atPath: layout.export)) ?? []).sorted()
        for name in exported {
            switch (name as NSString).pathExtension {
            case "app": try await zip(layout.export + "/" + name, as: name + ".zip")
            case "ipa", "pkg": file(name)
            default: break
            }
        }
        file("ExportOptions.plist")
        file("DistributionSummary.plist")
        return collected
    }
}
