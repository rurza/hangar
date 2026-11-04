import Foundation
import HangarCore

public enum ArtifactError: Error, Equatable, CustomStringConvertible {
    case zipFailed(name: String, exitCode: Int32)
    /// Some pieces could not be zipped or uploaded; the others were.
    case incomplete([String])

    public var description: String {
        switch self {
        case .zipFailed(let name, let exitCode): "ditto exited with status \(exitCode) while zipping \(name)"
        case .incomplete(let failures): failures.joined(separator: "; ")
        }
    }
}

/// What `ArtifactCollector` gathered, and a description of every piece it could not.
public struct ArtifactCollection: Sendable {
    public var artifacts: [(name: String, url: URL)] = []
    public var failures: [String] = []
}

/// Gathers what a job leaves behind for the build page: dSYMs, the result bundle, the exported product and the
/// export's property lists. Bundles are zipped with `ditto` into `<jobDirectory>/artifacts`; files are used in place.
/// Pieces that do not exist are skipped. Each piece is independent: one that cannot be zipped is logged and listed in
/// `failures`, and the rest are still collected (the result bundle is what explains a failed build).
public struct ArtifactCollector: Sendable {
    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner) {
        self.runner = runner
    }

    /// Throws only when the staging directory cannot be created.
    public func collect(
        layout: WorkspaceLayout, scheme: String, log: @escaping @Sendable (String) -> Void
    ) async throws -> ArtifactCollection {
        let fileManager = FileManager.default
        let staging = layout.jobDirectory + "/artifacts"
        try fileManager.createDirectory(atPath: staging, withIntermediateDirectories: true)
        var collection = ArtifactCollection()

        func zip(_ source: String, as name: String) async {
            guard fileManager.fileExists(atPath: source) else { return }
            let destination = staging + "/" + name
            log("zipping \(name)")
            do {
                let outcome = try await runner.run(
                    ProcessCommand(
                        executable: "/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", source, destination]),
                    onLine: log)
                guard outcome.exitCode == 0 else { throw ArtifactError.zipFailed(name: name, exitCode: outcome.exitCode) }
                collection.artifacts.append((name, URL(fileURLWithPath: destination)))
            } catch {
                log("error: \(error)")
                collection.failures.append("\(error)")
            }
        }
        func file(_ name: String) {
            let path = layout.export + "/" + name
            if fileManager.fileExists(atPath: path) { collection.artifacts.append((name, URL(fileURLWithPath: path))) }
        }

        await zip(layout.archive(scheme: scheme) + "/dSYMs", as: "\(scheme)-dSYMs.zip")
        await zip(layout.resultBundle, as: "\(scheme).xcresult.zip")
        let exported = ((try? fileManager.contentsOfDirectory(atPath: layout.export)) ?? []).sorted()
        for name in exported {
            switch (name as NSString).pathExtension {
            case "app": await zip(layout.export + "/" + name, as: name + ".zip")
            case "ipa", "pkg": file(name)
            default: break
            }
        }
        file("ExportOptions.plist")
        file("DistributionSummary.plist")
        return collection
    }
}
