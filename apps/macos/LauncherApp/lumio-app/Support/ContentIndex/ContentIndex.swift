import Foundation
import OSLog
import Synchronization

nonisolated private let indexLog = Logger(subsystem: "noah-code.Lumio", category: "ContentIndex")

/// What the OCR tab shows while there is nothing (yet) to list.
nonisolated struct ContentIndexStatus: Equatable, Sendable {
    var enabled: Bool
    /// Files with searchable text.
    var filesWithText: Int
    var indexing: Bool
    /// Files still to read in the running pass.
    var pending: Int
}

/// Live progress of the running pass, readable from any thread.
nonisolated final class ContentIndexProgress: Sendable {
    let running = Atomic<Bool>(false)
    let pending = Atomic<Int>(0)
}

/// Search by what is INSIDE images and PDFs (the launcher's OCR tab): text recognized by OCR
/// in images, scanned pages and pictures inside PDFs, plus the PDF text layer.
///
/// The launcher calls `search` (any thread, a few ms: one SQLite FTS query) and
/// `refreshIfStale` when it opens; the slow part (reading/OCR'ing files) runs on a
/// utility-priority task and only touches files that are new or changed since the last pass.
nonisolated final class ContentIndex: Sendable {
    static let shared = ContentIndex()

    private let store: ContentIndexStore?
    private let indexer: ContentIndexer?
    private let enabled = Atomic<Bool>(true)
    private let progress = ContentIndexProgress()

    private init() {
        store = ContentIndexStore(path: ContentIndexStore.defaultPath)
        let progress = progress
        indexer = store.map { ContentIndexer(store: $0, progress: progress) }
    }

    /// Call off the main thread (counts rows in SQLite).
    func status() -> ContentIndexStatus {
        ContentIndexStatus(
            enabled: store != nil && enabled.load(ordering: .relaxed),
            filesWithText: store?.textCount() ?? 0,
            indexing: progress.running.load(ordering: .relaxed),
            pending: progress.pending.load(ordering: .relaxed))
    }

    /// Files whose text contains the typed words. Call off the main thread.
    func search(_ term: String, limit: Int) -> [ContentHit] {
        guard let store, limit > 0, enabled.load(ordering: .relaxed) else { return [] }
        return store.search(term, limit: limit)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Re-reads the config and brings the index up to date, unless a pass ran recently with the
    /// same config. `force` skips that wait (config reload).
    @MainActor
    func refreshIfStale(force: Bool = false) {
        guard let indexer else { return }
        let config = ContentIndexConfig.load()
        enabled.store(config.enabled, ordering: .relaxed)
        Task { await indexer.refresh(config: config, force: force) }
    }
}

extension ContentIndexConfig {
    @MainActor
    static func load() -> ContentIndexConfig {
        let raw = (try? String(contentsOfFile: ConfigPathResolver.resolvedPath(), encoding: .utf8)) ?? ""
        return from(keyValues: ConfigFileLines.keyValues(raw), home: NSHomeDirectory())
    }
}

/// Runs index passes one at a time.
actor ContentIndexer {
    /// A pass after this long, when the launcher opens.
    static let minInterval: TimeInterval = 15 * 60
    /// Bound on directory entries looked at per pass (a root pointed at a huge tree).
    static let maxVisitedEntries = 300_000

    private let store: ContentIndexStore
    private let progress: ContentIndexProgress
    private var running: Task<Void, Never>?
    private var generation = 0
    private var lastConfig: ContentIndexConfig?
    private var lastFinished: Date?

    init(store: ContentIndexStore, progress: ContentIndexProgress) {
        self.store = store
        self.progress = progress
    }

    func refresh(config: ContentIndexConfig, force: Bool) {
        if let running {
            // A pass is already going with this config; a new config restarts it.
            guard config != lastConfig else { return }
            running.cancel()
        } else if !force, config == lastConfig, let lastFinished,
                  Date().timeIntervalSince(lastFinished) < Self.minInterval {
            return
        }
        generation += 1
        let pass = generation
        lastConfig = config
        let store = store
        let progress = progress
        progress.running.store(true, ordering: .relaxed)
        // .utility, not .background: at background QoS the first OCR (Vision loading/compiling its
        // text model) can stall for many minutes, holding up every file behind it.
        running = Task.detached(priority: .utility) {
            let completed = await Self.pass(store: store, config: config, progress: progress)
            await self.finished(pass, completed: completed)
        }
    }

    private func finished(_ pass: Int, completed: Bool) {
        guard pass == generation else { return }
        running = nil
        progress.running.store(false, ordering: .relaxed)
        progress.pending.store(0, ordering: .relaxed)
        if completed { lastFinished = Date() }
    }

    // MARK: - One pass

    nonisolated struct FoundFile: Sendable {
        let path: String
        let stamp: ContentIndexStore.FileStamp
    }

    /// false when cancelled before the end.
    private nonisolated static func pass(
        store: ContentIndexStore, config: ContentIndexConfig, progress: ContentIndexProgress
    ) async -> Bool {
        guard config.enabled else {
            // Turned off: don't keep text the user no longer wants indexed.
            if !store.stamps().isEmpty { store.removeAll() }
            return true
        }
        let started = Date()
        let found = scan(config)
        if Task.isCancelled { return false }

        let known = store.stamps()
        let foundPaths = Set(found.map(\.path))
        let gone = known.keys.filter { !foundPaths.contains($0) }
        if !gone.isEmpty { store.remove(paths: gone) }

        let todo = found.filter { known[$0.path] != $0.stamp }
        progress.pending.store(todo.count, ordering: .relaxed)
        for file in todo {
            if Task.isCancelled { return false }
            progress.pending.subtract(1, ordering: .relaxed)
            let text = await ContentTextExtractor.text(of: URL(fileURLWithPath: file.path), size: file.stamp.size)
            if Task.isCancelled { return false }
            store.upsert(path: file.path, stamp: file.stamp, text: text)
        }
        let seconds = Date().timeIntervalSince(started)
        indexLog.info(
            "content index: \(found.count) files, \(todo.count) read, \(gone.count) removed in \(seconds, format: .fixed(precision: 1))s")
        return true
    }

    /// Indexable files under the roots, newest first, at most `config.limit`.
    private nonisolated static func scan(_ config: ContentIndexConfig) -> [FoundFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let keySet = Set(keys)
        var files: [FoundFile] = []
        var seen = Set<String>()
        var visited = 0

        for root in config.roots where !config.isExcluded(root) {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                visited += 1
                if visited > maxVisitedEntries || Task.isCancelled { break }
                guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
                if values.isDirectory == true {
                    if enumerator.level >= config.depth
                        || config.skipDirNames.contains(url.lastPathComponent.lowercased())
                        || config.isExcluded(url.path)
                    {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true, ContentTextExtractor.canRead(url) else { continue }
                let path = url.path
                guard !config.isExcluded(path), seen.insert(path).inserted else { continue }
                files.append(FoundFile(
                    path: path,
                    stamp: .init(
                        mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                        size: Int64(values.fileSize ?? 0))))
            }
        }
        files.sort { $0.stamp.mtime > $1.stamp.mtime }
        return Array(files.prefix(config.limit))
    }
}
