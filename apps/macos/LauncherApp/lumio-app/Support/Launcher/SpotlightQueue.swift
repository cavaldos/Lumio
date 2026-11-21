//
//  SpotlightQueue.swift
//  lumio-app
//
//  Where Spotlight lookups (MDQuery) run. Never on Swift's cooperative pool (`Task.detached`):
//
//  A synchronous MDQueryExecute blocks its thread until the query is gathered, and gathering
//  needs another worker thread inside this process. The cooperative pool has one thread per
//  CPU core. Typing fast starts one file search per keystroke; once that many are blocked at
//  the same time, the queries wait for a thread the pool can never hand out, so they never
//  return. Every other task queues behind them, the core search included: the launcher shows
//  no results at all until it is restarted.
//
//  So the lookups run here instead: one serial GCD queue (its own thread, outside the pool),
//  one query at a time, and a lookup whose task was cancelled before its turn (the text
//  changed meanwhile) is skipped rather than run for nothing.
//

import Foundation

nonisolated enum SpotlightQueue {
    private static let queue = DispatchQueue(label: "com.cavaldos.Lumio.spotlight", qos: .userInitiated)

    /// Runs `work` on the Spotlight queue and returns what it returns. If the calling task is
    /// cancelled before `work` gets its turn, `skipped` comes back without running it. `work`
    /// gets the same check, to stop between two queries.
    static func run<T: Sendable>(
        skipped: T,
        _ work: @escaping @Sendable (_ isCancelled: @Sendable () -> Bool) -> T
    ) async -> T {
        let cancelled = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: cancelled.isSet ? skipped : work { cancelled.isSet })
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }
}

/// Set once from the cancelling thread, read on the Spotlight queue.
private nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
