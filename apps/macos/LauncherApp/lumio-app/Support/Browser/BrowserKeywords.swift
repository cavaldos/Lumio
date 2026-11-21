//
//  BrowserKeywords.swift
//  lumio-app
//
//  The search engines saved in your browser become search tags, like Fluent Search does:
//  a site search you set up in Chrome / Edge / Brave / Arc / Vivaldi ("Manage search engines
//  and site search", including the ones the browser adds by itself as you search a site) works
//  in Lumio as `<keyword>` ⇥ with no setup.
//
//  Read from the `keywords` table of each Chromium profile's `Web Data` database (read-only,
//  immutable: the browser keeps it locked). Safari has no custom search engines.
//

import Foundation
import SQLite3

nonisolated struct BrowserKeyword: Equatable, Sendable {
    /// What you type (`yt`, `wiki`, or a domain like `youtube.com` when the browser made it).
    let keyword: String
    let name: String
    /// Search URL with `{query}`.
    let template: String
}

nonisolated enum BrowserKeywords {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [BrowserKeyword] = []

    /// The last list read by `warm()`: no disk access (empty until the first warm-up).
    static var cached: [BrowserKeyword] { lock.withLock { cache } }

    /// Reads the browsers' search engines into the cache. Call off the main thread.
    static func warm() {
        let fresh = all()
        lock.withLock { cache = fresh }
    }

    static func all() -> [BrowserKeyword] {
        var seen = Set<String>()
        var out: [BrowserKeyword] = []
        for profile in BrowserHistory.profiles() {
            let db = profile.dir.appendingPathComponent("Web Data")
            guard FileManager.default.fileExists(atPath: db.path) else { continue }
            for keyword in read(db) where seen.insert(keyword.keyword).inserted {
                out.append(keyword)
            }
        }
        return out
    }

    private static func read(_ db: URL) -> [BrowserKeyword] {
        var handle: OpaquePointer?
        let path = db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db.path
        guard sqlite3_open_v2("file:\(path)?immutable=1", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else {
            sqlite3_close(handle)
            return []
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT short_name, keyword, url FROM keywords ORDER BY usage_count DESC"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var out: [BrowserKeyword] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(statement, 0),
                  let keyC = sqlite3_column_text(statement, 1),
                  let urlC = sqlite3_column_text(statement, 2)
            else { continue }
            let name = String(cString: nameC)
            let keyword = String(cString: keyC).lowercased()
            guard let template = convert(String(cString: urlC)), !keyword.isEmpty, !keyword.contains(" ")
            else { continue }
            out.append(BrowserKeyword(keyword: keyword, name: name, template: template))
        }
        return out
    }

    /// Chromium template → ours. `{searchTerms}` becomes `{query}`; Google's internal
    /// parameters (`{google:…}`) are dropped. nil when there is nowhere to put the text.
    static func convert(_ url: String) -> String? {
        guard url.contains("{searchTerms}") else { return nil }
        var out = url.replacingOccurrences(of: "{google:baseURL}", with: "https://www.google.com/")
        out = out.replacingOccurrences(of: "{searchTerms}", with: "{query}")
        // Remove any other {placeholder} the browser fills in itself (keeps our {query}).
        out = out.replacingOccurrences(of: #"\{(?!query\})[^}]*\}"#, with: "", options: .regularExpression)
        guard out.hasPrefix("http"), out.contains("{query}") else { return nil }
        return out
    }
}
