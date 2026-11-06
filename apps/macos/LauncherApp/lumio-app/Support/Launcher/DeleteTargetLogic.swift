import Foundation

/// Which paths Move to Trash / Empty Trash may act on. Pure, so it can be
/// unit-tested; `TrashService` does the actual work.
enum DeleteTargetLogic {
    /// Quick-folder results (Desktop, Documents, …, Applications, Trash) are
    /// navigation pins, not delete targets - Cmd+D must never trash the real
    /// folder behind one. They aren't covered by `isProtected` (most are ordinary
    /// home subfolders / `/Applications`), so they're excluded by id here. Cmd+D
    /// on the Trash pin is routed to Empty Trash (see `SpotlightBackend.trashAction`).
    static func isQuickFolderPin(_ id: String) -> Bool {
        id.hasPrefix(AppConstants.Launcher.QuickFolder.idPrefix)
    }

    /// URL-scheme targets contain a ":" and don't start at the filesystem root.
    static func isURLScheme(_ path: String) -> Bool {
        path.contains(":") && !path.hasPrefix("/")
    }

    /// Refuses to trash catastrophic targets: the filesystem root, the home
    /// directory itself, and the Trash. (Trash is now a pinned quick folder, so
    /// Cmd+D on it would otherwise try to recycle ~/.Trash into itself.)
    static func isProtected(_ path: String, homeDirectory: String) -> Bool {
        let p = normalize(path)
        if p.isEmpty || p == "/" { return true }
        if p == normalize(homeDirectory) { return true }
        if isTrashPath(path, homeDirectory: homeDirectory) { return true }
        return false
    }

    /// True when `path` is the user's Trash (`~/.Trash`). Used both to protect
    /// it from being trashed and to route Cmd+D on it to "Empty Trash".
    static func isTrashPath(_ path: String, homeDirectory: String) -> Bool {
        normalize(path) == normalize(homeDirectory) + "/.Trash"
    }

    /// Detail line for the Empty Trash confirmation, stressing permanence.
    static func emptyTrashDetail(itemCount: Int) -> String {
        "\(itemCount) item\(itemCount == 1 ? "" : "s") - deleted permanently"
    }

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

}
