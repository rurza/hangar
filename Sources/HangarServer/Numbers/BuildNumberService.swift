import Foundation
import GRDB
import HangarAppStoreConnect
import HangarCore

/// Build number = max(every known number) + 1, reserved atomically; a failed build burns its number.
public struct BuildNumberService: Sendable {
    let repository: BuildRepository
    let sources: @Sendable () async throws -> [any KnownNumberSource]

    public init(repository: BuildRepository, sources: @escaping @Sendable () async throws -> [any KnownNumberSource]) {
        self.repository = repository
        self.sources = sources
    }

    public func preview(app: App) async throws -> NumbersReport {
        let remote = try await queryRemote(app: app)
        let highest = try repository.highestAssigned(appID: app.id)
        return NumbersReport(
            appID: app.id, highestHangar: highest, next: Self.next(remote: remote.overall, local: highest),
            highestAppStoreConnect: remote.byName[AppStoreConnectBuildsSource.sourceName] ?? nil,
            // "Last" means highest: run numbers only grow.
            lastXcodeCloudRun: remote.byName[XcodeCloudRunsSource.sourceName] ?? nil,
            inFlight: try repository.inFlight(appID: app.id))
    }

    /// Sources are asked before the transaction; the local counter is read and advanced inside it.
    public func reserve(app: App, buildID: UUID) async throws -> Int {
        let remote = try await queryRemote(app: app).overall
        return try repository.inTransaction { db in
            let number = Self.next(remote: remote, local: try BuildRepository.highestAssigned(db, appID: app.id))
            try BuildRepository.reserveNumber(db, appID: app.id, number: number, buildID: buildID)
            try BuildRepository.setHighestAssigned(db, appID: app.id, number)
            return number
        }
    }

    /// Raises the counter so the next number is `next`; never lowers it.
    public func bump(app: App, to next: Int) async throws -> NumbersReport {
        let remote = try await queryRemote(app: app).overall
        try repository.inTransaction { db in
            // Re-checked inside the write transaction: the counter may have moved since the preview.
            let current = Self.next(remote: remote, local: try BuildRepository.highestAssigned(db, appID: app.id))
            guard next > current else { throw BuildNumberError.bumpNotHigher(current: current, requested: next) }
            try BuildRepository.setHighestAssigned(db, appID: app.id, next - 1)
        }
        return try await preview(app: app)
    }

    static func next(remote: Int?, local: Int?) -> Int { max(remote ?? 0, local ?? 0) + 1 }

    private func queryRemote(app: App) async throws -> (overall: Int?, byName: [String: Int?]) {
        let sources = try await sources()
        let results = await withTaskGroup(of: (Int, Result<Int?, Error>).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do { return (index, .success(try await source.highestNumber(for: app))) } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<Int?, Error>)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        var overall: Int?
        var byName: [String: Int?] = [:]
        // Source order, so the reported failure is deterministic.
        for (index, result) in results {
            let name = sources[index].name
            switch result {
            case .success(let number):
                byName[name] = number
                if let number { overall = max(overall ?? number, number) }
            case .failure(let error as BuildNumberError):
                throw error
            case .failure(let error):
                throw BuildNumberError.sourceUnavailable(source: name, reason: String(describing: error))
            }
        }
        return (overall, byName)
    }
}
