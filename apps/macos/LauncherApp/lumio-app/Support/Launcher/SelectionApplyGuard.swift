import Foundation

/// Decides whether a selected-text read that finished after the launcher was already on
/// screen may still be applied. The read is slow (Accessibility IPC), so the user may have
/// closed the launcher, typed, or picked a tab in the meantime; any of that wins over the
/// late result.
struct SelectionApplyGuard<Browse: Equatable> {
    /// The state right after `show()` returned, before the read finished.
    let queryAtShow: String
    let browseAtShow: Browse?

    func shouldApply(
        isOpen: Bool,
        dismissing: Bool,
        query: String,
        browse: Browse?,
        inScope: Bool,
        hasActiveCommand: Bool
    ) -> Bool {
        isOpen && !dismissing
            && query == queryAtShow
            && browse == browseAtShow
            && !inScope && !hasActiveCommand
    }
}
