//
//  RecentItems.swift
//  lumio-app
//
//  Suggestions for the empty field, like Fluent Search: the apps and files you use most,
//  so the thing you want is often one ⏎ away before you type anything.
//
//  Ranked by "frecency": every day a file was opened counts, recent days count more
//  (half-life of a few days), so a file you open daily beats one you opened once an hour ago.
//  Files that just landed in Downloads are suggested too.
//
//  Comes from the Spotlight index (kMDItemUsedDates / kMDItemLastUsedDate, the "opened on"
//  dates macOS keeps for every file), so it needs no history of its own. Cached for a short while: the launcher
//  opens many times a minute.
//
//  Turn off with `suggestions_on_open=false` in ~/.lumio/config.
//

import CoreServices
import Foundation

nonisolated struct RecentItem: Equatable, Sendable {
    let path: String
    let name: String
    let lastUsed: Date
    let isApp: Bool
    /// Arrived in ~/Downloads lately and not opened yet.
    var isNewDownload = false
    /// Frecency: higher = suggested first.
    var score: Double = 0
}

nonisolated enum RecentItems {
    static let configKey = "suggestions_on_open"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (at: Date, apps: [RecentItem], files: [RecentItem])?
    private static let cacheSeconds: TimeInterval = 20

    /// Whether to show suggestions on the empty field (default off: the round quick buttons show instead).
    @MainActor static var isEnabled: Bool {
        let raw = (try? String(contentsOfFile: ConfigPathResolver.resolvedPath(), encoding: .utf8)) ?? ""
        guard let value = SearchTags.configLines(raw).last(where: { $0.0 == configKey })?.1.lowercased()
        else { return false }
        return !["false", "0", "no", "off"].contains(value)
    }

    /// Most recently used apps and files, newest first. The Spotlight queries run on
    /// `SpotlightQueue`, never on Swift's task pool (see there why).
    static func recent(apps appLimit: Int, files fileLimit: Int) async -> (apps: [RecentItem], files: [RecentItem]) {
        // A fresh cache answers at once, without waiting behind a file search on the queue.
        typealias Lists = (apps: [RecentItem], files: [RecentItem])
        let lists: Lists = if let fresh = cached() {
            fresh
        } else {
            await SpotlightQueue.run(skipped: Lists(apps: [], files: [])) { _ in cached() ?? gather() }
        }
        return (Array(lists.apps.prefix(appLimit)), Array(lists.files.prefix(fileLimit)))
    }

    private static func cached() -> (apps: [RecentItem], files: [RecentItem])? {
        lock.withLock {
            guard let cache, Date().timeIntervalSince(cache.at) < cacheSeconds else { return nil }
            return (cache.apps, cache.files)
        }
    }

    /// Three Spotlight queries. Only ever called on `SpotlightQueue`.
    private static func gather() -> (apps: [RecentItem], files: [RecentItem]) {
        let ownBundle = Bundle.main.bundlePath
        let apps = query(
            "kMDItemContentType == 'com.apple.application-bundle' && kMDItemLastUsedDate >= $time.today(-30)",
            scopes: ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        )
        .filter { $0.path != ownBundle && !$0.path.contains("/Contents/") }
        .map { RecentItem(path: $0.path, name: displayName($0.path), lastUsed: $0.date, isApp: true, score: $0.score) }
        .sorted { $0.score > $1.score }

        let home = NSHomeDirectory()
        var files = query(
            "kMDItemLastUsedDate >= $time.today(-14) && kMDItemContentType != 'com.apple.application-bundle'"
                + " && kMDItemContentType != 'public.folder'",
            scopes: [home]
        )
        .filter { isUserFile($0.path, home: home) }
        .map { RecentItem(path: $0.path, name: ($0.path as NSString).lastPathComponent, lastUsed: $0.date,
                          isApp: false, score: $0.score) }

        // Just downloaded and not opened yet: worth a suggestion (decays over ~a day).
        let opened = Set(files.map(\.path))
        let downloads = query("kMDItemDateAdded >= $time.today(-2)", scopes: [home + "/Downloads"])
            .filter { !opened.contains($0.path) && isUserFile($0.path, home: home) }
            .map { hit in
                RecentItem(path: hit.path, name: (hit.path as NSString).lastPathComponent, lastUsed: hit.added ?? hit.date,
                           isApp: false, isNewDownload: true,
                           score: 1.5 * decay(hit.added ?? hit.date, halfLifeDays: 0.5))
            }
        files = (files + downloads).sorted { $0.score > $1.score }

        lock.lock()
        cache = (Date(), apps, files)
        lock.unlock()
        return (apps, files)
    }

    // MARK: - Spotlight

    private struct Hit {
        let path: String
        let date: Date
        let added: Date?
        let score: Double
    }

    /// Weight of a use `date` ago, halving every `halfLifeDays`.
    private static func decay(_ date: Date, halfLifeDays: Double) -> Double {
        let days = max(0, -date.timeIntervalSinceNow / 86_400)
        return pow(0.5, days / halfLifeDays)
    }

    private static func query(_ text: String, scopes: [String]) -> [Hit] {
        // Dates come back with the results when declared as sorting attributes (one round trip,
        // not one per file); the path is read per file.
        let usedDates = "kMDItemUsedDates" as CFString
        let sorting = [kMDItemLastUsedDate, kMDItemDateAdded, usedDates] as CFArray
        guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, sorting) else { return [] }
        MDQuerySetSearchScope(query, scopes as CFArray, 0)
        MDQuerySetMaxCount(query, 400)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        defer { MDQueryStop(query) }

        func value(_ attribute: CFString, _ index: CFIndex) -> AnyObject? {
            guard let raw = MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        }

        var out: [Hit] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let added = value(kMDItemDateAdded, index) as? Date
            guard let date = (value(kMDItemLastUsedDate, index) as? Date) ?? added else { continue }
            // One entry per day the file was opened (macOS keeps these); fall back to the last use.
            let days = (value(usedDates, index) as? [Date]) ?? []
            let uses = days.isEmpty ? [date] : days.suffix(30) + [date]
            let score = uses.reduce(0) { $0 + decay($1, halfLifeDays: 4) }
            out.append(Hit(path: path, date: date, added: added, score: score))
        }
        return out.sorted { $0.date > $1.date }
    }

    /// Files a person opens, not app data: nothing inside ~/Library, hidden folders or bundles.
    private static func isUserFile(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        let relative = path.dropFirst(home.count + 1)
        if relative.hasPrefix("Library/") { return false }
        let parts = relative.split(separator: "/")
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        let bundleExts = [".app/", ".photoslibrary/", ".bundle/", ".xcodeproj/", ".pkg/", ".framework/"]
        if bundleExts.contains(where: { path.contains($0) }) { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private static func displayName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
