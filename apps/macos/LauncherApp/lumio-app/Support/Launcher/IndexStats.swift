//
//  IndexStats.swift
//  lumio-app
//
//  What Lumio's own index holds right now, for Settings ▸ Indexing: how many apps, files and
//  folders, and when it was last brought up to date. Read straight from the index database,
//  read-only. Also whether the macOS Spotlight index (which the whole-Mac search uses) is on.
//

import Foundation
import SQLite3

nonisolated struct IndexStats: Equatable, Sendable {
    var apps = 0
    var files = 0
    var folders = 0
    var updated: Date?
    /// nil = could not tell.
    var spotlightOn: Bool?

    var total: Int { apps + files + folders }

    /// The core's default database (see bridge/ffi `default_db_path`).
    private static var databasePath: String {
        if let custom = ProcessInfo.processInfo.environment["LUMIO_DB_PATH"], !custom.isEmpty { return custom }
        return NSHomeDirectory() + "/Library/Application Support/lumio/lumio.db"
    }

    /// Reads the counts. Call off the main thread.
    static func read() -> IndexStats {
        var stats = IndexStats()
        var handle: OpaquePointer?
        if sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle {
            sqlite3_busy_timeout(handle, 400)
            var statement: OpaquePointer?
            let sql = "SELECT kind, COUNT(*), MAX(indexed_at_unix_s) FROM candidates GROUP BY kind"
            if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK {
                var newest: Int64 = 0
                while sqlite3_step(statement) == SQLITE_ROW {
                    let kind = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                    let count = Int(sqlite3_column_int64(statement, 1))
                    newest = max(newest, sqlite3_column_int64(statement, 2))
                    switch kind {
                    case "app": stats.apps = count
                    case "file": stats.files = count
                    case "folder": stats.folders = count
                    default: break
                    }
                }
                if newest > 0 { stats.updated = Date(timeIntervalSince1970: TimeInterval(newest)) }
            }
            sqlite3_finalize(statement)
        }
        sqlite3_close(handle)
        stats.spotlightOn = spotlightEnabled()
        return stats
    }

    /// `mdutil -s` on the data volume: "Indexing enabled." / "Indexing disabled."
    private static func spotlightEnabled() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        process.arguments = ["-s", "/System/Volumes/Data"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        if text.contains("indexing enabled") { return true }
        if text.contains("indexing disabled") || text.contains("indexing and searching disabled") { return false }
        return nil
    }
}
