import SwiftUI

extension LauncherView {
    /// Actions offered for the selected row (Cmd+K menu).
    var actionMenuDescriptors: [RowActionDescriptor] {
        guard let id = selectedResultID,
              let selected = displayedResults.first(where: { $0.id == id })
        else { return [] }
        return rowActionDescriptors(for: selected)
    }

    /// What the menu lists right now.
    var actionMenuRows: [RowActionDescriptor] {
        actionMenuDescriptors
    }

    /// Cmd+K. Opening with nothing to offer would show an empty box, so a row
    /// with no actions says so instead.
    func toggleActionMenu() {
        if isActionMenuOpen {
            closeActionMenu()
            return
        }
        guard !actionMenuDescriptors.isEmpty else {
            showBanner("Nothing to do here", style: .info, duration: 1.2)
            return
        }
        actionMenuIndex = 0
        withAnimation(Motion.Selection.glide) { isActionMenuOpen = true }
    }

    func closeActionMenu() {
        guard isActionMenuOpen else { return }
        withAnimation(Motion.Selection.glide) { isActionMenuOpen = false }
        actionMenuIndex = 0
    }

    /// Wraps at both ends, so holding one direction cycles rather than dead-ends.
    func moveActionMenuFocus(by offset: Int) {
        let count = actionMenuRows.count
        guard count > 0 else { return }
        actionMenuIndex = ((actionMenuIndex + offset) % count + count) % count
    }

    func runFocusedAction() {
        let rows = actionMenuRows
        guard rows.indices.contains(actionMenuIndex) else { return }
        activateActionMenuRow(rows[actionMenuIndex])
    }

    func activateActionMenuRow(_ descriptor: RowActionDescriptor) {
        if RowAction.isOne(descriptor.actionId) {
            closeActionMenu()
            activateRowAction(descriptor.actionId)
            return
        }
        closeActionMenu()
    }

    /// Keeps the focused row inside the list when the offered actions change
    /// under it.
    func clampActionMenuFocus() {
        let count = actionMenuRows.count
        guard count > 0 else {
            closeActionMenu()
            return
        }
        actionMenuIndex = min(actionMenuIndex, count - 1)
    }
}
