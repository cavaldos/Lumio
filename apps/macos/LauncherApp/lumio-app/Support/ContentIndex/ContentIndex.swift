import Foundation
import OSLog
import Synchronization

nonisolated private let indexLog = Logger(subsystem: "com.cavaldos.Lumio", category: "ContentIndex")

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
/// The launcher only ever reads the index (`search`, `status`: one SQLite query each). Reading
/// and OCR'ing files happens in a separate worker process (`ContentIndexWorker`), started when
/// the OCR tab is opened and gone when its pass is done, so Vision never loads in the launcher.
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

    /// The OCR tab was opened: re-reads the config and starts the worker, unless a pass ran
    /// recently with the same config. `force` skips that wait.
    @MainActor
    func refreshIfStale(force: Bool = false) {
        guard let indexer else { return }
        let config = ContentIndexConfig.load()
        enabled.store(config.enabled, ordering: .relaxed)
        Task { await indexer.refresh(config: config, force: force) }
    }

    /// Config reloaded: applies it without starting a pass. A running pass restarts with the
    /// new config; OCR turned off stops it and deletes the stored text.
    @MainActor
    func reloadConfig() {
        guard let indexer else { return }
        let config = ContentIndexConfig.load()
        enabled.store(config.enabled, ordering: .relaxed)
        Task { await indexer.configChanged(config) }
    }

    /// Ends a running pass (the app is quitting).
    func stopWorker() {
        indexer?.stopNow()
    }

    /// Launcher hidden: hand SQLite's page cache back.
    func releaseMemory() {
        store?.releaseMemory()
    }
}

extension ContentIndexConfig {
    @MainActor
    static func load() -> ContentIndexConfig {
        let raw = (try? String(contentsOfFile: ConfigPathResolver.resolvedPath(), encoding: .utf8)) ?? ""
        return from(keyValues: ConfigFileLines.keyValues(raw), home: NSHomeDirectory())
    }
}

/// Starts the OCR worker process and follows it. One pass at a time.
actor ContentIndexer {
    /// A new pass at most this often, when the OCR tab is opened.
    static let minInterval: TimeInterval = 15 * 60
    /// Bound on directory entries looked at per pass (a root pointed at a huge tree).
    static let maxVisitedEntries = 300_000

    private let store: ContentIndexStore
    private let progress: ContentIndexProgress
    /// Readable from `stopNow` (any thread, no await) while the actor may be busy.
    private let running = Mutex<WorkerHandle?>(nil)
    private var generation = 0
    private var lastConfig: ContentIndexConfig?
    private var lastFinished: Date?

    init(store: ContentIndexStore, progress: ContentIndexProgress) {
        self.store = store
        self.progress = progress
    }

    func refresh(config: ContentIndexConfig, force: Bool) {
        guard config.enabled else {
            disable(config)
            return
        }
        if running.withLock({ $0 != nil }) {
            // A pass is already going with this config; a new config restarts it.
            guard config != lastConfig else { return }
            stopNow()
        } else if !force, config == lastConfig, let lastFinished,
                  Date().timeIntervalSince(lastFinished) < Self.minInterval {
            return
        }
        lastConfig = config
        start()
    }

    func configChanged(_ config: ContentIndexConfig) {
        guard config.enabled else {
            disable(config)
            return
        }
        // Restart a running pass on the new config; otherwise the next tab open picks it up.
        if running.withLock({ $0 != nil }), config != lastConfig {
            refresh(config: config, force: true)
        }
    }

    /// Turned off: no worker, and don't keep text the user no longer wants indexed. Deleting
    /// rows is plain SQL, no reason to start a process for it.
    private func disable(_ config: ContentIndexConfig) {
        stopNow()
        lastConfig = config
        if !store.stamps().isEmpty { store.removeAll() }
    }

    /// Kills a running worker. Its exit is still reported to `exited`, which ignores it.
    nonisolated func stopNow() {
        guard let handle = running.withLock({ handle in defer { handle = nil }; return handle }) else { return }
        handle.stop()
    }

    private func start() {
        generation += 1
        let pass = generation
        guard let executable = Bundle.main.executableURL else { return }
        let progress = progress
        let handle = WorkerHandle(pass: pass)
        let process = Process()
        process.executableURL = executable
        process.arguments = [ContentIndexWorkerMessage.flag]
        // .utility, not .background: at background QoS the first OCR (Vision loading/compiling
        // its text model) can stall for many minutes, holding up every file behind it.
        process.qualityOfService = .utility
        process.standardInput = handle.stdin
        process.standardOutput = handle.stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let crashed = process.terminationReason == .uncaughtSignal
            let status = process.terminationStatus
            Task { await self?.exited(handle, completed: status == 0, crashed: crashed) }
        }
        handle.readMessages { message in
            switch message {
            case .pending(let count): progress.pending.store(count, ordering: .relaxed)
            case .reading: break
            }
        }
        do {
            try process.run()
        } catch {
            indexLog.error("content index: worker failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }
        handle.process = process
        running.withLock { $0 = handle }
        progress.pending.store(0, ordering: .relaxed)
        progress.running.store(true, ordering: .relaxed)
        indexLog.info("content index: worker \(process.processIdentifier) started")
    }

    private func exited(_ handle: WorkerHandle, completed: Bool, crashed: Bool) {
        // A crash on its own (not one we caused by stopping it): the file it was reading is
        // what killed it. Record it as read, with no text, so the next pass doesn't crash on
        // it again.
        if crashed, !handle.stopped, let path = handle.lastFile {
            let values = try? URL(fileURLWithPath: path).resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            store.upsert(
                path: path,
                stamp: .init(
                    mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    size: Int64(values?.fileSize ?? 0)),
                text: nil)
            indexLog.error("content index: worker crashed on \(path, privacy: .private); skipping it from now on")
        }
        guard handle.pass == generation else { return }
        running.withLock { if $0 === handle { $0 = nil } }
        progress.running.store(false, ordering: .relaxed)
        progress.pending.store(0, ordering: .relaxed)
        if completed { lastFinished = Date() }
    }

    // MARK: - One pass

    nonisolated struct FoundFile: Sendable {
        let path: String
        let stamp: ContentIndexStore.FileStamp
    }

    /// One pass, run inside the worker process. false when cancelled before the end.
    nonisolated static func pass(
        store: ContentIndexStore, config: ContentIndexConfig,
        report: (ContentIndexWorkerMessage) -> Void
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
        report(.pending(todo.count))
        for (index, file) in todo.enumerated() {
            if Task.isCancelled { return false }
            report(.reading(file.path))
            report(.pending(todo.count - index - 1))
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

/// One running worker: its process, the pipes to it, and what it last said.
nonisolated final class WorkerHandle: @unchecked Sendable {
    let pass: Int
    /// Never written to: the worker exits when it closes (see `ContentIndexWorker`).
    let stdin = Pipe()
    let stdout = Pipe()

    private let lock = NSLock()
    private var runningProcess: Process?
    private var wasStopped = false
    private var lastReading: String?
    private var buffer = Data()

    init(pass: Int) {
        self.pass = pass
    }

    var process: Process? {
        get { lock.withLock { runningProcess } }
        set { lock.withLock { runningProcess = newValue } }
    }

    /// True once the app stopped it (so its exit is not a crash worth acting on).
    var stopped: Bool { lock.withLock { wasStopped } }

    /// The file the worker was reading when it last reported.
    var lastFile: String? { lock.withLock { lastReading } }

    /// Calls `onMessage` for every line the worker prints, on a background queue.
    func readMessages(_ onMessage: @escaping @Sendable (ContentIndexWorkerMessage) -> Void) {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else {
                // EOF: the worker is gone.
                handle.readabilityHandler = nil
                return
            }
            for message in self.messages(appending: chunk) {
                if case .reading(let path) = message {
                    self.lock.withLock { self.lastReading = path }
                }
                onMessage(message)
            }
        }
    }

    /// Whole lines out of what has arrived so far; a partial line waits for the rest.
    private func messages(appending chunk: Data) -> [ContentIndexWorkerMessage] {
        lock.withLock {
            buffer.append(chunk)
            var out: [ContentIndexWorkerMessage] = []
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let message = ContentIndexWorkerMessage(line: line) { out.append(message) }
            }
            return out
        }
    }

    func stop() {
        let process = lock.withLock {
            wasStopped = true
            return runningProcess
        }
        // Closing stdin lets the worker exit on its own; terminate covers a worker stuck in OCR.
        try? stdin.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
    }
}
