//
//  BrowserTabs.swift
//  lumio-app
//
//  Open browser tabs as search results: Enter switches to the tab instead of opening a new
//  one. Reads tabs over AppleScript from browsers that are ALREADY running (it never launches
//  one). macOS asks once per browser for Automation permission ("Lumio wants to control …").
//
//  Supported: Safari, Google Chrome, Arc, Brave, Microsoft Edge, Vivaldi, Chromium, Opera.
//  Firefox has no AppleScript tab access.
//
//  The tab list is a snapshot taken in the background when the launcher opens (and when a
//  search tag is entered), so typing never waits on AppleScript.
//

import AppKit
import OSLog

nonisolated private let tabsLog = Logger(subsystem: "com.cavaldos.Lumio", category: "browser-tabs")

nonisolated struct BrowserTab: Equatable, Sendable {
    let browser: BrowserTabs.Browser
    let windowID: String
    let tabIndex: Int
    let title: String
    let url: String
    /// Path of the browser app, for the row icon.
    let appPath: String?

    var host: String {
        let host = URLComponents(string: url)?.host ?? url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Stable id for the row.
    var id: String { "tab|\(browser.rawValue)|\(windowID)|\(tabIndex)|\(url)" }
}

nonisolated final class BrowserTabs: @unchecked Sendable {
    static let shared = BrowserTabs()

    enum Browser: String, Sendable, CaseIterable {
        case safari, chrome, arc, brave, edge, vivaldi, chromium, opera

        var bundleID: String {
            switch self {
            case .safari: "com.apple.Safari"
            case .chrome: "com.google.Chrome"
            case .arc: "company.thebrowser.Browser"
            case .brave: "com.brave.Browser"
            case .edge: "com.microsoft.edgemac"
            case .vivaldi: "com.vivaldi.Vivaldi"
            case .chromium: "org.chromium.Chromium"
            case .opera: "com.operasoftware.Opera"
            }
        }

        var displayName: String {
            switch self {
            case .safari: "Safari"
            case .chrome: "Chrome"
            case .arc: "Arc"
            case .brave: "Brave"
            case .edge: "Edge"
            case .vivaldi: "Vivaldi"
            case .chromium: "Chromium"
            case .opera: "Opera"
            }
        }

        /// Safari names tabs `name`; every Chromium browser calls it `title`.
        fileprivate var titleProperty: String { self == .safari ? "name" : "title" }
    }

    /// Whether the app at `path` is one of the browsers Lumio reads.
    static func isBrowser(appPath: String) -> Bool {
        guard let id = Bundle(path: appPath)?.bundleIdentifier else { return false }
        return Browser.allCases.contains { $0.bundleID == id } || id == "org.mozilla.firefox"
    }

    private let queue = DispatchQueue(label: "com.cavaldos.Lumio.browser-tabs", qos: .userInitiated)
    private let lock = NSLock()
    private var tabs: [BrowserTab] = []
    private var refreshing = false
    private var lastRefresh = Date.distantPast

    /// The last snapshot. Empty until the first refresh finishes.
    var snapshot: [BrowserTab] {
        lock.lock(); defer { lock.unlock() }
        return tabs
    }

    /// Re-reads the tabs in the background; `completion` runs on the main thread when the list
    /// changed. Calls within `minInterval` of the last one are skipped.
    func refresh(minInterval: TimeInterval = 1.5, completion: (@MainActor @Sendable () -> Void)? = nil) {
        lock.lock()
        if refreshing || Date().timeIntervalSince(lastRefresh) < minInterval {
            lock.unlock()
            return
        }
        refreshing = true
        lock.unlock()

        let running = Self.runningBrowsers()
        queue.async { [self] in
            var fresh: [BrowserTab] = []
            for (browser, appPath) in running {
                fresh += Self.readTabs(of: browser, appPath: appPath)
            }
            lock.lock()
            let changed = fresh != tabs
            tabs = fresh
            refreshing = false
            lastRefresh = Date()
            lock.unlock()
            if changed, let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    /// Tabs whose title or address contains every word of `query` (case / accent-insensitive),
    /// best first: title starts with the text, then title contains it, then address only.
    func search(_ query: String, limit: Int) -> [BrowserTab] {
        let words = Self.fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let needle = Self.fold(query)
        let ranked: [(BrowserTab, Int)] = snapshot.compactMap { tab in
            let title = Self.fold(tab.title)
            let address = Self.fold(tab.host + " " + tab.url)
            guard words.allSatisfy({ title.contains($0) || address.contains($0) }) else { return nil }
            let score = title.hasPrefix(needle) ? 3
                : title.contains(needle) ? 2
                : tab.host.lowercased().hasPrefix(needle) ? 2
                : 1
            return (tab, score)
        }
        return ranked.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Brings the tab to the front: selects it in its window, raises the window, activates the browser.
    @discardableResult
    func activate(_ tab: BrowserTab) -> Bool {
        let source: String
        let app = "application id \"\(tab.browser.bundleID)\""
        switch tab.browser {
        case .safari:
            source = """
            tell \(app)
                set w to window id \(tab.windowID)
                set current tab of w to tab \(tab.tabIndex) of w
                set index of w to 1
                activate
            end tell
            """
        case .arc:
            source = """
            tell \(app)
                tell window id "\(tab.windowID)" to tell tab \(tab.tabIndex) to select
                activate
            end tell
            """
        default:
            source = """
            tell \(app)
                set w to window id \(tab.windowID)
                set active tab index of w to \(tab.tabIndex)
                set index of w to 1
                activate
            end tell
            """
        }
        if Self.run(source) != nil { return true }
        // The window or tab is gone (closed since the snapshot): open the address instead.
        guard let url = URL(string: tab.url) else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - AppleScript

    private static let fieldSep = "\u{1F}"
    private static let rowSep = "\u{1E}"

    /// Running browsers we can read, with their app path.
    private static func runningBrowsers() -> [(Browser, String?)] {
        let apps = NSWorkspace.shared.runningApplications
        return Browser.allCases.compactMap { browser in
            guard let app = apps.first(where: { $0.bundleIdentifier == browser.bundleID && !$0.isTerminated })
            else { return nil }
            return (browser, app.bundleURL?.path)
        }
    }

    /// One Apple Event per window (titles and URLs fetched as lists), then joined locally.
    private static func readTabs(of browser: Browser, appPath: String?) -> [BrowserTab] {
        let titleProp = browser.titleProperty
        let source = """
        set fs to character id 31
        set rs to character id 30
        set out to ""
        tell application id "\(browser.bundleID)"
            repeat with w in (every window)
                try
                    set wid to id of w
                    set ts to \(titleProp) of every tab of w
                    set us to URL of every tab of w
                    repeat with i from 1 to count of us
                        set u to item i of us
                        if u is missing value then set u to ""
                        set t to item i of ts
                        if t is missing value then set t to ""
                        set out to out & wid & fs & i & fs & t & fs & u & rs
                    end repeat
                end try
            end repeat
        end tell
        return out
        """
        guard let raw = run(source) else { return [] }
        return raw.components(separatedBy: rowSep).compactMap { row in
            let fields = row.components(separatedBy: fieldSep)
            guard fields.count == 4, let index = Int(fields[1]) else { return nil }
            let url = fields[3]
            // Skip blank / internal pages: nothing useful to switch to.
            guard !url.isEmpty, !url.hasPrefix("chrome://newtab"), !url.hasPrefix("arc://"),
                  url != "about:blank", url != "favorites://"
            else { return nil }
            let title = fields[2].isEmpty ? url : fields[2]
            return BrowserTab(browser: browser, windowID: fields[0], tabIndex: index,
                              title: title, url: url, appPath: appPath)
        }
    }

    /// NSAppleScript is not thread-safe: every script runs on `queue` or the caller's thread
    /// one at a time, guarded by this lock.
    private static let scriptLock = NSLock()

    private static func run(_ source: String) -> String? {
        scriptLock.lock(); defer { scriptLock.unlock() }
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743: the user said no to Automation for this browser; -600: browser quit.
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            tabsLog.debug("tab script failed: \(code, privacy: .public)")
            return nil
        }
        return result.stringValue ?? ""
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
