import Foundation
import OSLog
import SQLite3

nonisolated private let storeLog = Logger(subsystem: "com.cavaldos.Lumio", category: "ContentIndex")

/// SQLITE_TRANSIENT: SQLite copies bound strings before the call returns.
nonisolated private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A file whose text matched a search.
nonisolated struct ContentHit: Equatable, Sendable {
    let path: String
    let snippet: String?
}

/// On-disk text of indexed files (`~/Library/Application Support/lumio/content-index.db`).
///
/// `files` remembers every file looked at (with mtime/size, so unchanged files are never read
/// twice, even ones with no text); `texts` is an FTS5 trigram table over the folded text, which
/// gives substring search ("don" finds "hóa đơn"). Kept on disk so the launcher's memory stays flat.
nonisolated final class ContentIndexStore: @unchecked Sendable {
    struct FileStamp: Equatable, Sendable {
        let mtime: Double
        let size: Int64
    }

    /// Bump when what gets extracted changes: the index is rebuilt once on the next pass.
    /// 2: PDF pages with pictures are OCR'd too.
    private static let schemaVersion: Int32 = 2
    /// Text kept per file. Enough for the start of long PDFs; bounds the database size.
    static let maxStoredCharacters = 30_000

    /// One connection, used from the indexer and from searches; the lock serializes them.
    /// Writes are single small statements (the slow OCR runs outside the lock).
    private let lock = NSLock()
    private var db: OpaquePointer?

    init?(path: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            storeLog.error("open failed: \(path, privacy: .public)")
            sqlite3_close(handle)
            return nil
        }
        db = handle
        // The launcher and the OCR worker share this file: wait for the other one's write
        // instead of failing with "database is locked".
        sqlite3_busy_timeout(handle, 3000)
        // Searches touch a few pages; the default 2 MB cache would just sit in the launcher.
        exec("PRAGMA cache_size=-512")
        guard prepareSchema() else {
            sqlite3_close(handle)
            db = nil
            return nil
        }
    }

    deinit {
        sqlite3_close(db)
    }

    static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("lumio/content-index.db").path
    }

    // MARK: - Schema

    private func prepareSchema() -> Bool {
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        if userVersion() != Self.schemaVersion {
            exec("DROP TABLE IF EXISTS texts")
            exec("DROP TABLE IF EXISTS files")
        }
        let ok = exec("""
            CREATE TABLE IF NOT EXISTS files (
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL
            )
            """)
            && exec("CREATE VIRTUAL TABLE IF NOT EXISTS texts USING fts5(folded, body UNINDEXED, tokenize='trigram')")
        if ok { exec("PRAGMA user_version=\(Self.schemaVersion)") }
        return ok
    }

    private func userVersion() -> Int32 {
        var version: Int32 = 0
        query("PRAGMA user_version") { stmt in version = sqlite3_column_int(stmt, 0) }
        return version
    }

    // MARK: - Indexer side

    /// Every file looked at so far, with the stamp it had then.
    func stamps() -> [String: FileStamp] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: FileStamp] = [:]
        query("SELECT path, mtime, size FROM files") { stmt in
            guard let raw = sqlite3_column_text(stmt, 0) else { return }
            out[String(cString: raw)] = FileStamp(
                mtime: sqlite3_column_double(stmt, 1), size: sqlite3_column_int64(stmt, 2))
        }
        return out
    }

    /// Records a file and its text (nil / empty = looked at, nothing to search).
    func upsert(path: String, stamp: FileStamp, text: String?) {
        // Fold before taking the lock so searches never wait on it.
        let body = text.map { String($0.prefix(Self.maxStoredCharacters)) } ?? ""
        let folded = ContentSearchText.fold(body)
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN")
        deleteLocked(path: path)
        var id: Int64 = 0
        let inserted = run("INSERT INTO files(path, mtime, size) VALUES (?1, ?2, ?3)") { stmt in
            sqlite3_bind_text(stmt, 1, path, -1, sqliteTransient)
            sqlite3_bind_double(stmt, 2, stamp.mtime)
            sqlite3_bind_int64(stmt, 3, stamp.size)
        }
        if inserted { id = sqlite3_last_insert_rowid(db) }
        if inserted, !folded.isEmpty {
            run("INSERT INTO texts(rowid, folded, body) VALUES (?1, ?2, ?3)") { stmt in
                sqlite3_bind_int64(stmt, 1, id)
                sqlite3_bind_text(stmt, 2, folded, -1, sqliteTransient)
                sqlite3_bind_text(stmt, 3, body, -1, sqliteTransient)
            }
        }
        exec(inserted ? "COMMIT" : "ROLLBACK")
    }

    func remove(paths: some Sequence<String>) {
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN")
        for path in paths { deleteLocked(path: path) }
        exec("COMMIT")
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM texts")
        exec("DELETE FROM files")
        exec("VACUUM")
    }

    private func deleteLocked(path: String) {
        run("DELETE FROM texts WHERE rowid IN (SELECT id FROM files WHERE path = ?1)") { stmt in
            sqlite3_bind_text(stmt, 1, path, -1, sqliteTransient)
        }
        run("DELETE FROM files WHERE path = ?1") { stmt in
            sqlite3_bind_text(stmt, 1, path, -1, sqliteTransient)
        }
    }

    // MARK: - Search side

    /// Files that have searchable text. Counts FTS5's docsize table (one small row per file)
    /// rather than `texts`, which would read every stored text through the page cache.
    func textCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        var count = 0
        query("SELECT count(*) FROM texts_docsize") { stmt in count = Int(sqlite3_column_int64(stmt, 0)) }
        return count
    }

    /// Hands the connection's page cache back (the launcher was hidden).
    func releaseMemory() {
        lock.lock(); defer { lock.unlock() }
        sqlite3_db_release_memory(db)
    }

    /// Files whose text contains every 3+ character word of `term`, best match first.
    func search(_ term: String, limit: Int) -> [ContentHit] {
        guard limit > 0, let match = ContentSearchText.matchExpression(for: term) else { return [] }
        var rows: [(path: String, body: String)] = []
        lock.lock()
        let sql = """
            SELECT files.path, texts.body FROM texts JOIN files ON files.id = texts.rowid
            WHERE texts MATCH ?1 ORDER BY texts.rank LIMIT ?2
            """
        query(sql, bind: { stmt in
            sqlite3_bind_text(stmt, 1, match, -1, sqliteTransient)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }) { stmt in
            guard let path = sqlite3_column_text(stmt, 0) else { return }
            let body = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            rows.append((String(cString: path), body))
        }
        lock.unlock()
        // Snippets are built outside the lock: the indexer can write meanwhile.
        return rows.map { ContentHit(path: $0.path, snippet: ContentSearchText.snippet(in: $0.body, query: term)) }
    }

    // MARK: - SQLite helpers (caller holds the lock, except during init)

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "rc \(rc)"
            storeLog.error("\(sql.prefix(40), privacy: .public): \(message, privacy: .public)")
            sqlite3_free(error)
        }
        return rc == SQLITE_OK
    }

    /// Runs a statement that returns no rows.
    @discardableResult
    private func run(_ sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            storeLog.error("prepare failed: \(sql.prefix(40), privacy: .public)")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func query(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }, row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            storeLog.error("prepare failed: \(sql.prefix(40), privacy: .public)")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }
}
