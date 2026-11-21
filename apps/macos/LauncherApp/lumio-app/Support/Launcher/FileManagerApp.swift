//
//  FileManagerApp.swift
//  lumio-app
//
//  Which app opens folders and shows files ("Show in Finder", ⌘F). Finder by default, but
//  any third-party file manager works (Path Finder, ForkLift, QSpace, Commander One…).
//
//  ~/.lumio/config:
//
//    file_manager=auto            follow the system file viewer (default, see below)
//    file_manager=Path Finder     an app name in /Applications
//    file_manager=com.binarynights.ForkLift   a bundle id
//    file_manager=/Applications/QSpace Pro.app   a path
//    file_manager=finder          always Finder
//
//  `auto`: a file manager that registers itself as the system file viewer (the global
//  `NSFileViewer` default) is used for everything; otherwise Finder.
//

import AppKit

enum FileManagerApp {
    static let configKey = "file_manager"

    /// nil until first use / after a config reload.
    private static var resolved: Resolved?

    private struct Resolved {
        /// nil = Finder.
        let appURL: URL?
        let name: String
        /// The app is the system file viewer: revealing through NSWorkspace already lands in it
        /// and selects the file.
        let isSystemViewer: Bool
    }

    /// "Finder", "Path Finder"…, for labels ("Show in Path Finder").
    static var name: String { current.name }

    /// The chosen app, nil when it is Finder.
    static var appURL: URL? { current.appURL }

    static func reload() { resolved = nil }

    /// Opens a folder in the chosen file manager.
    static func openFolder(_ path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let app = current.appURL {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, error in
                // The app refused or vanished: fall back to Finder rather than doing nothing.
                if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            }
        } else {
            NSWorkspace.shared.open(url, configuration: config) { _, _ in }
        }
    }

    /// Shows a file or folder selected in its parent folder.
    static func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let state = current
        if state.appURL == nil || state.isSystemViewer {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // A file manager that isn't the system viewer: open the parent folder in it.
            openFolder(url.deletingLastPathComponent().path)
        }
    }

    // MARK: - Settings switch

    /// The raw `file_manager` value ("auto" when unset).
    static var choice: String { configValue() }

    /// What the Settings switch offers: Automatic, Finder, then the file managers found on
    /// this Mac. `value` is what gets written to the config.
    static func options() -> [(label: String, value: String)] {
        var out: [(String, String)] = []
        let viewer = systemViewerApp().map(appName)
        out.append((viewer.map { "Automatic (\($0))" } ?? "Automatic (Finder)", "auto"))
        out.append(("Finder", "finder"))
        let known = ["Path Finder", "ForkLift", "QSpace Pro", "QSpace", "Commander One",
                     "Marta", "Nimble Commander", "Bloom", "Fileside", "Transmit"]
        for name in known where findApp(name) != nil {
            out.append((name, name))
        }
        // Whatever is set in the config but not in the list (a bundle id, a path).
        let current = choice
        if !out.contains(where: { $0.1.caseInsensitiveCompare(current) == .orderedSame }),
           !["", "auto", "system", "default", "finder", "com.apple.finder"].contains(current.lowercased())
        {
            out.append((findApp(current).map(appName) ?? current, current))
        }
        return out
    }

    /// Saves the choice to ~/.lumio/config (other lines untouched) and applies it at once.
    @discardableResult
    static func setChoice(_ value: String) -> Bool {
        let path = ConfigPathResolver.resolvedPath()
        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var lines = ConfigFileLines.parse(raw)
        ConfigFileLines.upsert(&lines, key: configKey, value: value)
        do {
            try ConfigFileLines.render(lines).write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        reload()
        return true
    }

    // MARK: - Resolving the setting

    private static var current: Resolved {
        if let resolved { return resolved }
        let value = configValue()
        let result = resolve(value)
        resolved = result
        return result
    }

    private static func configValue() -> String {
        let raw = (try? String(contentsOfFile: ConfigPathResolver.resolvedPath(), encoding: .utf8)) ?? ""
        return SearchTags.configLines(raw).last(where: { $0.0 == configKey })?.1 ?? "auto"
    }

    private static let finder = Resolved(appURL: nil, name: "Finder", isSystemViewer: false)

    private static func resolve(_ value: String) -> Resolved {
        let viewer = systemViewerApp()
        let wanted = value.trimmingCharacters(in: .whitespaces)
        switch wanted.lowercased() {
        case "", "auto", "system", "default":
            guard let viewer else { return finder }
            return Resolved(appURL: viewer, name: appName(viewer), isSystemViewer: true)
        case "finder", "com.apple.finder":
            return finder
        default:
            guard let app = findApp(wanted) else { return finder }
            let same = viewer.map { $0.standardizedFileURL == app.standardizedFileURL } ?? false
            return Resolved(appURL: app, name: appName(app), isSystemViewer: same)
        }
    }

    /// The app behind the global `NSFileViewer` default (nil = unset or Finder). A helper app
    /// inside another app's bundle stands for that outer app.
    private static func systemViewerApp() -> URL? {
        guard let id = UserDefaults.standard.string(forKey: "NSFileViewer"),
              id.lowercased() != "com.apple.finder",
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return nil }
        return outermostApp(url)
    }

    /// App name, bundle id or path → app URL.
    private static func findApp(_ value: String) -> URL? {
        let fm = FileManager.default
        if value.hasPrefix("/") || value.hasPrefix("~") {
            let path = (value as NSString).expandingTildeInPath
            return fm.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        if !value.contains(" "), value.contains("."), !value.hasSuffix(".app"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
        {
            return url
        }
        let file = value.hasSuffix(".app") ? value : value + ".app"
        for dir in ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications",
                    "/Applications/Utilities"] {
            let path = dir + "/" + file
            if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// `/Applications/Some File Manager.app/Contents/Helpers/Viewer.app` → `/Applications/Some File Manager.app`.
    private static func outermostApp(_ url: URL) -> URL {
        let path = url.path
        guard let range = path.range(of: ".app/") else { return url }
        return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
    }

    private static func appName(_ url: URL) -> String {
        (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }
}
