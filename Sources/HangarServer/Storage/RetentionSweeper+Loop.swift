import Foundation
import Logging

extension RetentionSweeper {
    /// Sweeps now and then every `interval` until the task is cancelled. A failed sweep is logged and retried next time.
    public func run(
        every interval: Duration = .seconds(3600), clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) async {
        let logger = Logger(label: "app.hangar.server.retention")
        while !Task.isCancelled {
            do {
                let removed = try sweep(now: now())
                if !removed.isEmpty { logger.info("removed \(removed.count) expired job directories") }
            } catch {
                logger.error("retention sweep failed: \(error)")
            }
            do { try await clock.sleep(for: interval) } catch { return }
        }
    }
}
