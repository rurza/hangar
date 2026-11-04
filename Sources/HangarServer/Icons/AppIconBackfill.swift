import Foundation
import HangarCore
import Logging
import Synchronization

/// Stores icons for apps that have none, resolving them in the background: one task per app, and at most one
/// attempt per app per hour. `waitForIdle()` lets callers (tests) await the work in flight.
public final class AppIconBackfill: Sendable {
    static let retryInterval: TimeInterval = 3600

    private struct State {
        var lastAttempt: [UUID: Date] = [:]
        var tasks: [UUID: Task<Void, Never>] = [:]
    }

    private let resolver: AppIconResolver
    private let apps: AppRepository
    private let now: @Sendable () -> Date
    private let state = Mutex(State())
    private let logger = Logger(label: "app.hangar.server.icons")

    public init(resolver: AppIconResolver, apps: AppRepository, now: @escaping @Sendable () -> Date = Date.init) {
        self.resolver = resolver
        self.apps = apps
        self.now = now
    }

    /// Starts resolving the icon of every app in `candidates` without one, unless that app is already being resolved
    /// or was tried within the hour. Returns at once.
    public func fill(_ candidates: [App]) {
        let current = now()
        state.withLock { state in
            for app in candidates where app.iconURL == nil && state.tasks[app.id] == nil {
                if let last = state.lastAttempt[app.id], current.timeIntervalSince(last) < Self.retryInterval { continue }
                state.lastAttempt[app.id] = current
                // The task's own removal takes this lock, so it cannot run before the insertion below.
                state.tasks[app.id] = Task { [self] in
                    await resolve(app)
                    _ = self.state.withLock { $0.tasks.removeValue(forKey: app.id) }
                }
            }
        }
    }

    /// Returns once no resolution is in flight.
    public func waitForIdle() async {
        while let task = state.withLock({ $0.tasks.values.first }) { await task.value }
    }

    private func resolve(_ app: App) async {
        guard let url = await resolver.iconURL(ascAppID: app.appStoreConnectAppID) else { return }
        do {
            try apps.setIcon(id: app.id, url: url)
        } catch {
            logger.debug("storing the icon of \(app.slug) failed: \(error)")
        }
    }
}
