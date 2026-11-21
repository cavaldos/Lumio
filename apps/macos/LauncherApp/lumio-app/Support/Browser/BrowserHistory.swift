//
//  BrowserHistory.swift
//  lumio-app
//
//  Recently visited pages of one site, for search tags: `drive` + Tab lists the Google Drive
//  docs you opened lately, `yt` + Tab your recent videos. Read-only, local, nothing leaves
//  the Mac.
//
//  Reads the history database of Chromium browsers (Chrome, Arc, Brave, Edge, Vivaldi,
//  Chromium), every profile. The browser keeps the file locked while running, so it is
//  opened `immutable` (no locks taken, nothing written).
//
//  Safari's history is read too once Lumio has Full Disk Access (System Settings ▸ Privacy &
//  Security ▸ Full Disk Access). Without it macOS refuses the file and Safari is skipped.
//

import AppKit
import Foundation
import SQLite3

nonisolated struct HistoryPage: Equatable, Sendable {
    let url: String
    let title: String
    let lastVisit: Date
    let visitCount: Int
    /// Path of the browser app the page came from, for the row icon.
    var appPath: String? = nil
}

nonisolated enum BrowserHistory {
    /// `~/Library/Application Support/<dir>` of each Chromium browser.
    private static let browserDirs = [
        "Google/Chrome",
        "Arc/User Data",
        "BraveSoftware/Brave-Browser",
        "Microsoft Edge",
        "Vivaldi",
        "Chromium",
    ]

    /// Folder under Application Support → the browser's bundle id.
    private static let bundleIDs = [
        "Google/Chrome": "com.google.Chrome",
        "Arc/User Data": "company.thebrowser.Browser",
        "BraveSoftware/Brave-Browser": "com.brave.Browser",
        "Microsoft Edge": "com.microsoft.edgemac",
        "Vivaldi": "com.vivaldi.Vivaldi",
        "Chromium": "org.chromium.Chromium",
    ]

    /// App path of the browser that owns `file` (a profile's History / Bookmarks), or Safari's.
    static func appPath(forDataFile file: URL) -> String? {
        let path = file.path
        if path.contains("/Library/Safari/") {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")?.path
        }
        for (dir, id) in bundleIDs where path.contains("/Application Support/\(dir)/") {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
        }
        return nil
    }

    /// Every Chromium profile folder on this Mac (Default, Profile 1, …), with its browser's name.
    static func profiles() -> [(browser: String, dir: URL)] {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        var found: [(String, URL)] = []
        for dir in browserDirs {
            let root = support.appendingPathComponent(dir)
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            let browser = dir.split(separator: "/").first.map(String.init) ?? dir
            for name in names.sorted() where name == "Default" || name.hasPrefix("Profile ") {
                found.append((browser, root.appendingPathComponent(name)))
            }
        }
        return found
    }

    /// What Lumio can and cannot read, one line per browser file. macOS protects other apps'
    /// data: a blocked folder looks like "nothing found" unless it is reported.
    /// `Lumio --browser-check <file>` writes this; Settings shows a summary.
    static func accessReport() -> [String] {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        var lines: [String] = []
        for dir in browserDirs {
            let root = support.appendingPathComponent(dir)
            guard fm.fileExists(atPath: root.path) else { continue }
            do {
                let names = try fm.contentsOfDirectory(atPath: root.path)
                let profiles = names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
                lines.append("\(dir): folder readable, profiles: \(profiles.joined(separator: ", "))")
                for profile in profiles {
                    let base = root.appendingPathComponent(profile)
                    for file in ["History", "Bookmarks", "Web Data"] {
                        let url = base.appendingPathComponent(file)
                        guard fm.fileExists(atPath: url.path) else {
                            lines.append("  \(profile)/\(file): not there")
                            continue
                        }
                        let handle = fopen(url.path, "r")
                        if let handle {
                            fclose(handle)
                            var detail = "readable"
                            if file == "History" {
                                detail += ", \(queryChromium(url, likeURL: "%", text: "", limit: 100_000).count) pages"
                            }
                            lines.append("  \(profile)/\(file): \(detail)")
                        } else {
                            lines.append("  \(profile)/\(file): BLOCKED (\(String(cString: strerror(errno))))")
                        }
                    }
                }
            } catch {
                lines.append("\(dir): BLOCKED (\((error as NSError).localizedDescription))")
            }
        }
        for file in ["History.db", "Bookmarks.plist"] {
            let url = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/" + file)
            let handle = fopen(url.path, "r")
            if let handle {
                fclose(handle)
                lines.append("Safari/\(file): readable")
            } else {
                lines.append("Safari/\(file): BLOCKED (\(String(cString: strerror(errno)))) - needs Full Disk Access")
            }
        }
        return lines
    }

    /// True when a browser's data folder exists but macOS refuses to let Lumio list it
    /// (cheap: one directory listing per browser, no databases opened).
    static func isBlocked() -> Bool {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        for dir in browserDirs {
            let root = support.appendingPathComponent(dir)
            guard fm.fileExists(atPath: root.path) else { continue }
            if (try? fm.contentsOfDirectory(atPath: root.path)) == nil { return true }
        }
        return false
    }

    /// History databases on this Mac (one per browser profile).
    static func databases() -> [URL] {
        profiles().map { $0.dir.appendingPathComponent("History") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Any visited page whose title or address contains every typed word, for normal (untagged)
    /// searches. Pages visited often and lately first.
    static func search(_ text: String, limit: Int) -> [HistoryPage] {
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return [] }
        var pages: [HistoryPage] = []
        for db in databases() {
            pages += queryChromium(db, likeURL: "%", text: text, limit: 60)
        }
        pages += querySafari(safariDatabase, likeURL: "%", text: text, limit: 60)
        let needle = text.lowercased()
        var seen = Set<String>()
        return pages
            .filter { !isSearchPage($0.url) && !isLoginPage($0.url) }
            .map { page -> (HistoryPage, Double) in
                let days = max(0, -page.lastVisit.timeIntervalSinceNow / 86_400)
                var score = log2(Double(page.visitCount) + 1) + 3 * pow(0.5, days / 7)
                if page.title.lowercased().hasPrefix(needle) { score += 3 }
                return (page, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
            .filter { seen.insert(dedupeKey($0)).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Search-engine result pages ("cats - Google Search"): the web row already covers them.
    private static func isSearchPage(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("google.") && lower.contains("/search?")
            || lower.contains("bing.com/search") || lower.contains("duckduckgo.com/?q")
    }

    private static func isLoginPage(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("accounts.google.") || lower.contains("/signin") || lower.contains("/login")
            || lower.contains("/oauth") || lower.contains("/sso")
    }

    /// Pages of `tag`'s site, newest first, one per title. `text` narrows by title / address.
    static func recent(for tag: SearchTag, matching text: String, limit: Int) -> [HistoryPage] {
        guard let domain = tag.domain else { return [] }
        let host = domain.split(separator: "/").first.map(String.init) ?? domain
        var pages: [HistoryPage] = []
        for db in databases() {
            pages += queryChromium(db, likeURL: "%\(host)%", text: text, limit: 300)
        }
        pages += querySafari(safariDatabase, likeURL: "%\(host)%", text: text, limit: 300)
        var seen = Set<String>()
        return pages
            .filter { tag.matches(url: $0.url) && !isNoise($0, tag: tag) }
            .sorted { $0.lastVisit > $1.lastVisit }
            .filter { seen.insert(dedupeKey($0)).inserted }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - SQLite

    /// Chromium stores times as microseconds since 1601-01-01.
    private static let chromiumEpochOffset: Double = 11_644_473_600

    static var safariDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/History.db")
    }

    static func queryChromium(_ db: URL, likeURL: String, text: String, limit: Int) -> [HistoryPage] {
        let words = text.split(separator: " ").map { "%\($0)%" }
        var sql = """
        SELECT url, title, last_visit_time, visit_count FROM urls
        WHERE hidden = 0 AND url LIKE ?1
        """
        for index in words.indices {
            sql += " AND (title LIKE ?\(index + 2) OR url LIKE ?\(index + 2))"
        }
        sql += " ORDER BY last_visit_time DESC LIMIT \(limit)"
        // immutable=1: read without taking locks (Chrome holds the file in exclusive mode).
        return run(sql, on: db, immutable: true, likeURL: likeURL, words: words) { micros in
            Date(timeIntervalSince1970: micros / 1_000_000 - chromiumEpochOffset)
        }
    }

    /// Safari: seconds since 2001-01-01, title per visit. Opened normally (read-only), not
    /// immutable: Safari writes through a WAL, and immutable would miss today's visits.
    static func querySafari(_ db: URL, likeURL: String, text: String, limit: Int) -> [HistoryPage] {
        guard FileManager.default.isReadableFile(atPath: db.path) else { return [] }
        let words = text.split(separator: " ").map { "%\($0)%" }
        var sql = """
        SELECT i.url, v.title, MAX(v.visit_time) AS last, i.visit_count
        FROM history_items i JOIN history_visits v ON v.history_item = i.id
        WHERE i.url LIKE ?1
        """
        for index in words.indices {
            sql += " AND (v.title LIKE ?\(index + 2) OR i.url LIKE ?\(index + 2))"
        }
        sql += " GROUP BY i.id ORDER BY last DESC LIMIT \(limit)"
        return run(sql, on: db, immutable: false, likeURL: likeURL, words: words) { seconds in
            Date(timeIntervalSinceReferenceDate: seconds)
        }
    }

    /// Runs a `url, title, time, visits` query. `?1` is the address pattern, `?2…` the words.
    private static func run(
        _ sql: String, on db: URL, immutable: Bool, likeURL: String, words: [String],
        date: (Double) -> Date
    ) -> [HistoryPage] {
        var handle: OpaquePointer?
        let path = db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db.path
        let uri = "file:\(path)" + (immutable ? "?immutable=1" : "?mode=ro")
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return []
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 200)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, likeURL, -1, transient)
        for (index, word) in words.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 2), word, -1, transient)
        }

        let app = appPath(forDataFile: db)
        var pages: [HistoryPage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let urlC = sqlite3_column_text(statement, 0) else { continue }
            let url = String(cString: urlC)
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let time = sqlite3_column_double(statement, 2)
            let visits = Int(sqlite3_column_int64(statement, 3))
            pages.append(HistoryPage(
                url: url, title: title.isEmpty ? url : title,
                lastVisit: date(time), visitCount: visits, appPath: app
            ))
        }
        return pages
    }

    // MARK: - Cleanup

    /// Sign-in pages, redirects and bare home pages are not worth suggesting.
    private static func isNoise(_ page: HistoryPage, tag: SearchTag) -> Bool {
        if isLoginPage(page.url) { return true }
        guard let parts = URLComponents(string: page.url) else { return true }
        // The site's own front page ("https://www.youtube.com/") adds nothing to the search row.
        return (parts.path.isEmpty || parts.path == "/") && (parts.query ?? "").isEmpty
            && (parts.fragment ?? "").isEmpty
    }

    /// The same doc visited at several addresses (…/edit, …/edit#heading) shows once.
    private static func dedupeKey(_ page: HistoryPage) -> String {
        page.title.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
