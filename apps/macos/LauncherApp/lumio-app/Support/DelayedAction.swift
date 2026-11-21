import Foundation

/// One pending action that runs after a delay unless it is cancelled or replaced first.
///
/// Used to defer work that must never happen while something is on screen: the delay can
/// be cancelled when the thing reappears, and `condition` is checked once more on the
/// main actor right before the action runs, so a cancel that loses a race with the wake-up
/// still cannot slip the action through.
@MainActor
final class DelayedAction {
    private var task: Task<Void, Never>?

    /// Replaces any pending action. `condition` is evaluated after the delay; `false` drops
    /// the action. Nothing is retained once the task finishes or is cancelled.
    func schedule(
        after delay: Duration,
        if condition: @escaping @MainActor () -> Bool = { true },
        _ action: @escaping @MainActor () async -> Void
    ) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, condition() else { return }
            await action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
