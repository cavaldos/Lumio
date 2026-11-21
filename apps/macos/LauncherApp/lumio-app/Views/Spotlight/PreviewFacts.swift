import AppKit

/// Disk and LaunchServices answers the preview pane's chips and actions need. Those lists are
/// rebuilt on every launcher render, which means every keystroke, every arrow press and every
/// hovered row. `urlForApplication(toOpen:)` can take tens of ms for a file type it hasn't
/// seen yet, and Finder names and symlink resolution each touch the disk, so typing stalled.
/// Each answer is cached per path. The default-app lookup runs off the main thread: a render
/// never waits for it, and `onLoad` asks for one more render once the answer is in.
enum PreviewFacts {
    /// Plenty for one session of browsing. Past this the cache starts over.
    private static let limit = 400

    private static var names: [String: String] = [:]
    /// path → the app that opens it. A nil value means there is no such app.
    private static var apps: [String: URL?] = [:]
    private static var uninstallable: [String: Bool] = [:]
    private static var running: [String: Bool] = [:]
    private static var runningStamp = Date.distantPast
    private static var pending: Set<String> = []

    /// Finder's name for the file or folder at `path`.
    static func displayName(_ path: String) -> String {
        if let name = names[path] { return name }
        let name = FileManager.default.displayName(atPath: path)
        if names.count >= limit { names.removeAll(keepingCapacity: true) }
        names[path] = name
        return name
    }

    /// The app that opens `path`. Returns nil while the lookup is still running (`onLoad` runs
    /// when it finishes) and when no app opens the file.
    static func defaultApp(for path: String, onLoad: @escaping @MainActor () -> Void) -> URL? {
        if let known = apps[path] { return known }
        guard pending.insert(path).inserted else { return nil }
        Task {
            let app = await Task.detached(priority: .userInitiated) {
                NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path))
            }.value
            pending.remove(path)
            if apps.count >= limit { apps.removeAll(keepingCapacity: true) }
            apps[path] = .some(app)
            onLoad()
        }
        return nil
    }

    /// The app lives in /Applications or ~/Applications, and is not Lumio itself.
    static func canUninstall(_ path: String) -> Bool {
        if let known = uninstallable[path] { return known }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let home = NSHomeDirectory() + "/Applications/"
        let result = (real.hasPrefix("/Applications/") || real.hasPrefix(home))
            && real != Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if uninstallable.count >= limit { uninstallable.removeAll(keepingCapacity: true) }
        uninstallable[path] = result
        return result
    }

    /// Whether the app at `path` is running. Only decides a label ("Open" or "Switch to App")
    /// and which actions are listed. The actions look the app up again when clicked, so an
    /// answer up to a second old is fine.
    static func isRunning(_ path: String) -> Bool {
        let now = Date()
        if now.timeIntervalSince(runningStamp) > 1 {
            running.removeAll(keepingCapacity: true)
            runningStamp = now
        }
        if let known = running[path] { return known }
        let result = SpotlightOpener.runningApp(at: path) != nil
        running[path] = result
        return result
    }

    static func purge() {
        names.removeAll()
        apps.removeAll()
        uninstallable.removeAll()
        running.removeAll()
    }
}
