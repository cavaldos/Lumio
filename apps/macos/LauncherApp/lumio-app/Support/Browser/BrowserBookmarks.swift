//
//  BrowserBookmarks.swift
//  lumio-app
//
//  Your browser bookmarks as search results, like Fluent Search: they show up in normal
//  searches, `bookmark` ⇥ lists them all, and every bookmark folder becomes a tag of its own
//  (a folder "Work" → `work` ⇥ lists and searches the bookmarks in it).
//
//  Read-only, local. Chromium browsers keep bookmarks in a `Bookmarks` JSON file per profile;
//  Safari in ~/Library/Safari/Bookmarks.plist, readable once Lumio has Full Disk Access.
//  Re-read only when a file changes.
//

import Foundation

nonisolated struct Bookmark: Equatable, Sendable {
    let title: String
    let url: String
    /// Folder names from the top, e.g. ["Bookmarks Bar", "Work"].
    let folders: [String]
    let browser: String
    /// Path of the browser app, for the row icon.
    var appPath: String? = nil

    var folderLine: String { folders.isEmpty ? browser : folders.joined(separator: " › ") }
}

nonisolated enum BrowserBookmarks {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (stamp: String, bookmarks: [Bookmark])?

    /// All bookmarks of every browser and profile (deduplicated by address).
    static func all() -> [Bookmark] {
        let files = sources()
        let stamp = files.map { "\($0.url.path)@\(modified($0.url))" }.joined(separator: "|")
        lock.lock()
        if let cache, cache.stamp == stamp { lock.unlock(); return cache.bookmarks }
        lock.unlock()

        var seen = Set<String>()
        var out: [Bookmark] = []
        for source in files {
            let found = source.isSafari ? readSafari(source.url) : readChromium(source.url, browser: source.browser)
            for bookmark in found where seen.insert(bookmark.url).inserted {
                out.append(bookmark)
            }
        }
        lock.lock(); cache = (stamp, out); lock.unlock()
        return out
    }

    /// Bookmarks whose title or address contains every word, optionally only inside `folder`
    /// (any depth). Title-prefix matches first. Empty text = everything in scope, in file order.
    /// `cachedOnly`: answer from memory without touching the disk (for the main thread).
    static func search(_ text: String, folder: String? = nil, limit: Int, cachedOnly: Bool = false) -> [Bookmark] {
        let words = fold(text).split(separator: " ").map(String.init)
        let needle = fold(text)
        let scoped = (cachedOnly ? cached : all()).filter { bookmark in
            guard let folder else { return true }
            return bookmark.folders.contains { fold($0) == fold(folder) }
        }
        guard !words.isEmpty else { return Array(scoped.prefix(limit)) }
        return scoped
            .compactMap { bookmark -> (Bookmark, Int)? in
                let title = fold(bookmark.title)
                let haystack = title + " " + fold(bookmark.url)
                guard words.allSatisfy(haystack.contains) else { return nil }
                return (bookmark, title.hasPrefix(needle) ? 2 : title.contains(needle) ? 1 : 0)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Reads the bookmarks into the cache. Call off the main thread.
    static func warm() { _ = all() }

    /// Bookmarks as last read: no disk access (empty until the first `all()` / `warm()`).
    static var cached: [Bookmark] { lock.withLock { cache?.bookmarks ?? [] } }

    /// Folder names worth a tag: user folders, not the built-in roots. `cachedOnly` answers
    /// from memory (for the main thread).
    static func folderNames(cachedOnly: Bool = false) -> [String] {
        let roots: Set<String> = ["bookmarks bar", "other bookmarks", "mobile bookmarks", "favorites",
                                  "bookmarksmenu", "bookmarks menu", "reading list", "favourites"]
        var names: [String] = []
        for bookmark in (cachedOnly ? cached : all()) {
            for folder in bookmark.folders where !roots.contains(folder.lowercased()) && !names.contains(folder) {
                names.append(folder)
            }
        }
        return names
    }

    // MARK: - Files

    private struct Source {
        let url: URL
        let browser: String
        let isSafari: Bool
    }

    private static func sources() -> [Source] {
        var out = BrowserHistory.profiles().compactMap { profile -> Source? in
            let file = profile.dir.appendingPathComponent("Bookmarks")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return Source(url: file, browser: profile.browser, isSafari: false)
        }
        let safari = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
        if FileManager.default.isReadableFile(atPath: safari.path) {
            out.append(Source(url: safari, browser: "Safari", isSafari: true))
        }
        return out
    }

    private static func modified(_ url: URL) -> TimeInterval {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
    }

    // MARK: - Chromium: {"roots": {"bookmark_bar": {...}, "other": {...}, "synced": {...}}}

    static func readChromium(_ file: URL, browser: String) -> [Bookmark] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any]
        else { return [] }
        let app = BrowserHistory.appPath(forDataFile: file)
        var out: [Bookmark] = []
        func walk(_ node: [String: Any], path: [String]) {
            let name = node["name"] as? String ?? ""
            if node["type"] as? String == "url", let url = node["url"] as? String {
                out.append(Bookmark(title: name.isEmpty ? url : name, url: url, folders: path, browser: browser, appPath: app))
            }
            for child in node["children"] as? [[String: Any]] ?? [] {
                walk(child, path: node["type"] as? String == "folder" ? path + [name] : path)
            }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let root = roots[key] as? [String: Any] { walk(root, path: []) }
        }
        return out
    }

    // MARK: - Safari: nested WebBookmarkTypeList / WebBookmarkTypeLeaf dictionaries

    static func readSafari(_ file: URL) -> [Bookmark] {
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        let app = BrowserHistory.appPath(forDataFile: file)
        var out: [Bookmark] = []
        func walk(_ node: [String: Any], path: [String]) {
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let url = node["URLString"] as? String else { return }
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? url
                out.append(Bookmark(title: title, url: url, folders: path, browser: "Safari", appPath: app))
            case "WebBookmarkTypeList":
                let title = node["Title"] as? String ?? ""
                // The Reading List is not bookmarks.
                if title == "com.apple.ReadingList" { return }
                let next = title.isEmpty ? path : path + [title == "BookmarksBar" ? "Favorites" : title]
                for child in node["Children"] as? [[String: Any]] ?? [] { walk(child, path: next) }
            default:
                for child in node["Children"] as? [[String: Any]] ?? [] { walk(child, path: path) }
            }
        }
        walk(plist, path: [])
        return out
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
