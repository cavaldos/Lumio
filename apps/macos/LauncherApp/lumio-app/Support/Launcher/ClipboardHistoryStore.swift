import AppKit
import Combine
import Foundation

/// Runs clipboard writes off the main thread, one at a time. Their ORDER is
/// the caller's to establish (see `ClipboardHistoryStore.writeChain`).
private actor ClipboardWriter {
    static let shared = ClipboardWriter()

    /// Records the clip, then trims the database to the user's limits in the same
    /// hop, so the stored history never outgrows the setting between launches.
    func record(content: String, appBundleID: String?, limits: (text: Int, image: Int)) -> Int64? {
        let id = EngineBridge.shared.recordClipboard(content: content, appBundleID: appBundleID)
        EngineBridge.shared.trimClipboardHistory(textKeep: limits.text, imageKeep: limits.image)
        return id
    }

    /// A lowered limit has to reach the disk, or the clips come back next launch.
    /// Trimmed images take their files with them (core sweeps the directory).
    func trim(limits: (text: Int, image: Int)) {
        EngineBridge.shared.trimClipboardHistory(textKeep: limits.text, imageKeep: limits.image)
    }

    /// Reading, decoding and encoding the image happen in a helper process
    /// (`ClipboardImageWorker`): a screenshot is tens of MB that the launcher
    /// would otherwise keep mapped. Only the row is recorded here.
    /// `fallbackLabel` names raw pixels; an image copied as a file is named after it.
    func recordImage(
        changeCount: Int, appBundleID: String?, fallbackLabel: String,
        limits: (text: Int, image: Int)
    ) async -> (stored: StoredClipboardImage, storeID: Int64, label: String)? {
        guard let result = await ClipboardImageWorker.capture(changeCount: changeCount) else {
            return nil
        }
        let label = result.fileName ?? fallbackLabel
        guard
            let storeID = EngineBridge.shared.recordClipboardImage(
                label: label, imageHash: result.hash, appBundleID: appBundleID)
        else {
            return nil
        }
        EngineBridge.shared.trimClipboardHistory(textKeep: limits.text, imageKeep: limits.image)
        return (result.stored, storeID, label)
    }

    func delete(id: Int64) {
        EngineBridge.shared.deleteClipboardEntry(id: id)
    }

    func setPinned(id: Int64, pinned: Bool) {
        EngineBridge.shared.setClipboardPinned(id: id, pinned: pinned)
    }

    func clear() {
        EngineBridge.shared.clearClipboardHistory()
    }
}

/// One row of the history, as the list needs it: metadata and a short preview, like a
/// Maccy item's title. The clip's full text stays in SQLite and is loaded on demand
/// (`ClipboardHistoryStore.content(of:)`) when it is pasted or previewed - 300 clips
/// of up to 30,000 characters were tens of MB resident for nothing.
struct ClipboardHistoryEntry: Identifiable, Equatable {
    let id: UUID
    /// Leading characters of the clip: all that is kept in memory for a stored row.
    let preview: String
    /// Last time it was copied.
    let capturedAt: Date
    /// First time it was copied, and how many times since (re-copies included).
    let firstCapturedAt: Date
    let copyCount: Int
    /// App it was copied from, when known.
    let appBundleID: String?
    /// Derived once, not per render: rescanning text on every body evaluation
    /// stutters keyboard navigation.
    let title: String
    /// Of the FULL clip, not of `preview`.
    let lineCount: Int
    let characterCount: Int
    /// Stands in for the clip's text when comparing: the core's dedupe hash, so a new
    /// copy is matched against stored rows without keeping their strings.
    let contentKey: String
    /// Row id in the persisted history, when this clip came from (or reached)
    /// the database. Without it, deleting a clip here would leave it in the
    /// stored corpus - a clip the user believes they erased.
    let storeID: Int64?
    /// Pinned clips list first and are never trimmed.
    var isPinned: Bool
    /// The full text of a clip copied this session, held only until its row exists
    /// (`attachingStoreID`) - the one copy there is until then. Nil for every stored
    /// row. It also outlives a failed write, which is the only copy of that clip.
    let pendingContent: String?

    /// A clip just copied: everything is derived from `content`, which is kept as
    /// `pendingContent` until the database has it.
    init(
        capturing content: String,
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        firstCapturedAt: Date? = nil,
        copyCount: Int = 1,
        appBundleID: String? = nil,
        storeID: Int64? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.preview = ClipboardText.preview(of: content)
        self.capturedAt = capturedAt
        self.firstCapturedAt = firstCapturedAt ?? capturedAt
        self.copyCount = copyCount
        self.appBundleID = appBundleID
        self.title = ClipboardText.title(from: preview)
        self.lineCount = ClipboardText.lineCount(of: content)
        self.characterCount = content.count
        self.contentKey = ClipboardContentKey.make(for: content)
        self.storeID = storeID
        self.isPinned = isPinned
        self.pendingContent = content
    }

    /// A row read back from the database as a preview.
    init(stored row: EngineBridge.ClipboardEntry) {
        id = UUID()
        preview = row.content
        capturedAt = row.copiedAt
        firstCapturedAt = row.firstCopiedAt
        copyCount = row.copyCount ?? 1
        appBundleID = row.appBundleID
        title = ClipboardText.title(from: row.content)
        lineCount = row.lineCount ?? ClipboardText.lineCount(of: row.content)
        characterCount = row.contentLength ?? row.content.count
        contentKey = row.contentHash
        storeID = row.id
        isPinned = row.pinned ?? false
        pendingContent = nil
    }

    private init(copying other: Self, storeID: Int64?, pendingContent: String?) {
        id = other.id
        preview = other.preview
        capturedAt = other.capturedAt
        firstCapturedAt = other.firstCapturedAt
        copyCount = other.copyCount
        appBundleID = other.appBundleID
        title = other.title
        lineCount = other.lineCount
        characterCount = other.characterCount
        contentKey = other.contentKey
        self.storeID = storeID
        isPinned = other.isPinned
        self.pendingContent = pendingContent
    }

    /// Same clip once its row exists: the text now lives on disk, so it is dropped here.
    func attachingStoreID(_ storeID: Int64) -> Self {
        Self(copying: self, storeID: storeID, pendingContent: nil)
    }
}

final class ClipboardHistoryStore: ObservableObject {
    enum MonitoringMode {
        case foreground
        case background

        var interval: TimeInterval {
            switch self {
            case .foreground:
                return AppConstants.Launcher.Clipboard.foregroundPollInterval
            case .background:
                return AppConstants.Launcher.Clipboard.backgroundPollInterval
            }
        }
    }

    @Published private(set) var entries: [ClipboardHistoryEntry] = []
    /// Apart from `entries` because the two share no search key and no row
    /// shape. The storage underneath is one table.
    @Published private(set) var imageEntries: [ClipboardImageEntry] = []

    private var maxEntries = ClipboardHistoryStore.resolveMaxEntries()
    private var maxImageEntries = ClipboardHistoryStore.resolveMaxImageEntries()
    /// Bumped by `clearHistory`, so a capture that raced ahead of the clear can
    /// tell that the list it was joining is gone.
    private var historyGeneration = 0
    /// Every write runs after the one before it. Actor isolation gives mutual
    /// exclusion, not ordering: two tasks created independently reach the
    /// writer either way round.
    private var writeChain: Task<Void, Never>?
    private let maxStoredCharacters = AppConstants.Launcher.Clipboard.maxStoredCharacters

    /// Re-reads the clipboard section of `~/.lumio/config` and applies it live, so file-only
    /// clipboard settings take effect on config reload (`Cmd+Shift+;`) without a restart.
    /// Matches the `reloadFromConfig()` convention used by ThemeStore. Every clipboard key
    /// is applied from a single parse here, so adding a key is one more `apply` line below,
    /// not a new reload method.
    func reloadFromConfig() {
        let values = ClipboardHistoryStore.loadConfigValues()
        applyMaxEntries(ClipboardHistoryStore.resolveMaxEntries(from: values))
        applyMaxImageEntries(ClipboardHistoryStore.resolveMaxImageEntries(from: values))
    }

    private func applyMaxEntries(_ newValue: Int) {
        guard newValue != maxEntries else { return }
        maxEntries = newValue
        Self.trim(&entries, to: maxEntries, isPinned: \.isPinned)
        trimStoredHistory()
    }

    private func applyMaxImageEntries(_ newValue: Int) {
        guard newValue != maxImageEntries else { return }
        maxImageEntries = newValue
        Self.trim(&imageEntries, to: maxImageEntries, isPinned: \.isPinned)
        trimStoredHistory()
    }

    /// The limits as the database enforces them. Queued behind pending writes so a clip
    /// still being recorded is trimmed too, not left to outlive the setting.
    private var storedLimits: (text: Int, image: Int) { (maxEntries, maxImageEntries) }

    private func trimStoredHistory() {
        let limits = storedLimits
        enqueueWrite { await ClipboardWriter.shared.trim(limits: limits) }
    }

    /// Keeps the newest `limit` unpinned rows; pinned rows never count and never go.
    private static func trim<Row>(_ rows: inout [Row], to limit: Int, isPinned: (Row) -> Bool) {
        guard rows.count > limit else { return }
        var kept = 0
        rows.removeAll { row in
            if isPinned(row) { return false }
            kept += 1
            return kept > limit
        }
    }

    private func enqueueWrite(_ work: @escaping @Sendable () async -> Void) {
        let previous = writeChain
        writeChain = Task {
            await previous?.value
            await work()
        }
    }

    /// Reads every `key=value` pair from the active config file once, or an empty map when
    /// the file is missing/unreadable. One parse feeds all clipboard settings.
    private static func loadConfigValues() -> [String: String] {
        let path = ConfigPathResolver.resolvedPath()
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        return ConfigFileLines.keyValues(raw)
    }

    private static func resolveMaxEntries() -> Int {
        resolveMaxEntries(from: loadConfigValues())
    }

    /// `clipboard_history_limit`, defaulting to 300 when missing or out of [10, 1000].
    private static func resolveMaxEntries(from values: [String: String]) -> Int {
        ClipboardLimits.historyLimit(from: values)
    }

    private static func resolveMaxImageEntries() -> Int {
        resolveMaxImageEntries(from: loadConfigValues())
    }

    /// Capped separately from text, and far lower: megabytes, not characters.
    private static func resolveMaxImageEntries(from values: [String: String]) -> Int {
        ClipboardLimits.imageLimit(from: values)
    }

    private var monitoringMode: MonitoringMode = .foreground
    // nonisolated(unsafe) so the nonisolated deinit can call invalidate()
    // on these without going through the actor.
    nonisolated(unsafe) private var timer: Timer?
    nonisolated(unsafe) private var burstTimer: Timer?
    private var remainingBurstSamples = 0
    private var lastChangeCount: Int

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        startMonitoring()
        loadPersistedHistory()
    }

    /// History outlives the app now: the in-memory list is seeded from the
    /// stored corpus so `c"` shows what was copied before the last quit. Only
    /// previews come back; a clip's text is fetched when it is used.
    private func loadPersistedHistory() {
        let limit = maxEntries
        let imageLimit = maxImageEntries
        let previewCharacters = AppConstants.Launcher.Clipboard.previewCharacters
        let generation = historyGeneration
        Task { [weak self] in
            let stored = await Task.detached(priority: .utility) {
                // A database written under a bigger limit (or the old 1000 default) is
                // brought down to this one before anything is read from it.
                EngineBridge.shared.trimClipboardHistory(textKeep: limit, imageKeep: imageLimit)
                return (
                    text: EngineBridge.shared.clipboardEntries(
                        limit: limit, previewCharacters: previewCharacters),
                    // Mapped here: each image row stats its file.
                    images: EngineBridge.shared.clipboardEntries(
                        kind: AppConstants.Launcher.Clipboard.imageKind, limit: imageLimit
                    ).compactMap(Self.restoredImageEntry)
                )
            }.value
            guard let self, generation == self.historyGeneration else { return }
            if self.entries.isEmpty {
                self.entries = stored.text.map(ClipboardHistoryEntry.init(stored:))
            }
            if self.imageEntries.isEmpty {
                self.imageEntries = stored.images
            }
        }
    }

    /// A row whose file is gone is dropped rather than shown broken: the bytes
    /// are the clip, and without them there is nothing to paste.
    nonisolated private static func restoredImageEntry(from stored: EngineBridge.ClipboardEntry)
        -> ClipboardImageEntry?
    {
        guard let url = ClipboardImageFiles.fileURL(forHash: stored.contentHash),
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let byteSize = attributes[.size] as? Int
        else {
            return nil
        }
        return ClipboardImageEntry(
            label: stored.content,
            hash: stored.contentHash,
            capturedAt: stored.copiedAt,
            firstCapturedAt: stored.firstCopiedAt,
            copyCount: stored.copyCount ?? 1,
            pixelSize: ClipboardImageFiles.pixelSize(ofFileAt: url) ?? .zero,
            byteSize: byteSize,
            appBundleID: stored.appBundleID,
            storeID: stored.id,
            isPinned: stored.pinned ?? false)
    }

    /// Off the main thread, but the row id comes BACK: without it `deleteEntry`
    /// has nothing to remove on disk and the clip returns next launch.
    private func persist(_ content: String, entryID: UUID, app: String?) {
        let limits = storedLimits
        enqueueWrite { [weak self] in
            let storeID = await ClipboardWriter.shared.record(
                content: content, appBundleID: app, limits: limits)
            guard let self, let storeID else { return }
            await self.attachStoreID(storeID, to: entryID)
        }
    }

    /// Gives the entry its persisted id (and lets go of its text, which the database
    /// now holds), or forgets the row when the entry was deleted while the write was
    /// in flight.
    private func attachStoreID(_ storeID: Int64, to entryID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            // The user deleted it before the write landed: forget it on disk
            // too, or it comes back.
            enqueueWrite { await ClipboardWriter.shared.delete(id: storeID) }
            return
        }
        let existing = entries[index]
        entries[index] = existing.attachingStoreID(storeID)
        // Pinned before its row existed: the pin has to reach disk too.
        if existing.isPinned {
            enqueueWrite { await ClipboardWriter.shared.setPinned(id: storeID, pinned: true) }
        }
    }

    /// Forgets every clip, in memory and on disk. The promise that makes
    /// persisting clipboard history acceptable in the first place.
    func clearHistory() {
        entries.removeAll()
        imageEntries.removeAll()
        historyGeneration += 1
        enqueueWrite { await ClipboardWriter.shared.clear() }
    }

    deinit {
        timer?.invalidate()
        burstTimer?.invalidate()
    }

    /// The clips containing `term` (case-insensitive), in list order. The match runs in
    /// the core over each clip's whole text, off the main thread: scanning resident
    /// strings here would need them all resident. The core says WHICH rows match; the
    /// rows themselves come from the list, so identity and pins stay as they are.
    /// Clips whose row is not written yet are matched here against their pending text.
    func search(_ term: String) async -> [ClipboardHistoryEntry] {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return entries }

        // The list is trimmed to `maxEntries` (pinned ones aside), so this reaches every
        // row it holds. Only ids are used: a one-character preview keeps the rest of the
        // text out of this process.
        let limit = entries.count + maxEntries
        let matched = await Task.detached(priority: .userInitiated) {
            Set(
                EngineBridge.shared.clipboardEntries(
                    query: normalized, limit: limit, previewCharacters: 1
                ).map(\.id))
        }.value
        // Read AFTER the hop: clips copied or deleted meanwhile are judged as they are now.
        return entries.filter { entry in
            if let pending = entry.pendingContent {
                return pending.localizedCaseInsensitiveContains(normalized)
            }
            return entry.storeID.map(matched.contains) ?? false
        }
    }

    /// The row in the list, for a UI that holds only its id.
    func entry(for id: UUID) -> ClipboardHistoryEntry? {
        entries.first { $0.id == id }
    }

    /// A clip's text, loaded when it is pasted or previewed: from memory when the clip
    /// is too fresh to be on disk, otherwise from the database off the main thread.
    /// `maxCharacters` > 0 cuts it (the preview pane draws a few thousand). Nil when
    /// the clip is gone.
    func content(of id: UUID, maxCharacters: Int = 0) async -> String? {
        guard let entry = entry(for: id) else { return nil }
        if let pending = entry.pendingContent {
            return maxCharacters > 0 ? String(pending.prefix(maxCharacters)) : pending
        }
        guard let storeID = entry.storeID else { return nil }
        return await Task.detached(priority: .userInitiated) {
            EngineBridge.shared.clipboardContent(id: storeID, maxCharacters: maxCharacters)
        }.value
    }

    func togglePin(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned.toggle()
        persistPin(storeID: entries[index].storeID, pinned: entries[index].isPinned)
    }

    func toggleImagePin(id: String) {
        guard let index = imageEntries.firstIndex(where: { $0.id == id }) else { return }
        imageEntries[index].isPinned.toggle()
        persistPin(storeID: imageEntries[index].storeID, pinned: imageEntries[index].isPinned)
    }

    /// No row id yet means the write is in flight; `attachStoreID` sends the pin then.
    private func persistPin(storeID: Int64?, pinned: Bool) {
        guard let storeID else { return }
        enqueueWrite { await ClipboardWriter.shared.setPinned(id: storeID, pinned: pinned) }
    }

    func deleteEntry(id: UUID) {
        let storeIDs = entries.filter { $0.id == id }.compactMap(\.storeID)
        entries.removeAll { $0.id == id }
        guard !storeIDs.isEmpty else { return }
        enqueueWrite {
            for storeID in storeIDs { await ClipboardWriter.shared.delete(id: storeID) }
        }
    }

    /// Inserts `entry` at the front and drops anything beyond `maxEntries`.
    private func prepend(_ entry: ClipboardHistoryEntry) {
        entries.insert(entry, at: 0)
        Self.trim(&entries, to: maxEntries, isPinned: \.isPinned)
    }

    func setMonitoringMode(_ mode: MonitoringMode) {
        guard monitoringMode != mode else { return }
        monitoringMode = mode
        startMonitoring()
    }

    private func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: monitoringMode.interval, repeats: true) { [weak self] _ in
            // Timer fires on RunLoop.main; assumeIsolated avoids a needless
            // Task hop while satisfying Swift 6's Sendable-closure check.
            MainActor.assumeIsolated {
                self?.captureLatestClipboardIfNeeded()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func captureLatestClipboardIfNeeded() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        startBurstCaptureWindow()

        // One cross-process read of the type list, shared by both gates: this
        // runs on every copy made anywhere in the OS.
        let types = pasteboard.types ?? []
        // Checked BEFORE the text is read, let alone stored: a password
        // manager marks its clip concealed precisely so history tools skip it,
        // and history is now written to disk. The core cannot enforce this -
        // pasteboard markers only exist on this side. Images land on disk too,
        // so it runs before either branch.
        if typesAreConcealed(types) { return }

        // Before the file bail: an image copied in Finder IS a file reference.
        if captureImageIfPresent(pasteboard, types: types) { return }
        if typesCarryFileReference(types, pasteboard) { return }

        guard var text = pasteboard.string(forType: .string) else { return }
        if text.count > maxStoredCharacters {
            let originalCount = text.count
            text = String(text.prefix(maxStoredCharacters))
            text += "\n\n[truncated from \(originalCount) chars]"
        }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let app = Self.sourceAppBundleID()
        let captured: ClipboardHistoryEntry
        let key = ClipboardContentKey.make(for: text)
        if let existingIndex = entries.firstIndex(where: { $0.contentKey == key }) {
            // Keep the existing id so SwiftUI identity survives the re-capture.
            let existing = entries.remove(at: existingIndex)
            captured = ClipboardHistoryEntry(
                capturing: text, id: existing.id,
                firstCapturedAt: existing.firstCapturedAt, copyCount: existing.copyCount + 1,
                appBundleID: app ?? existing.appBundleID, storeID: existing.storeID,
                isPinned: existing.isPinned)
        } else {
            captured = ClipboardHistoryEntry(capturing: text, appBundleID: app)
        }
        prepend(captured)
        // Re-copying replaces the stored row, so the id is re-attached here
        // rather than assumed to be the one this entry already carried.
        persist(text, entryID: captured.id, app: app)
    }

    /// Files and records a copied image, reporting whether the copy was one.
    private func captureImageIfPresent(
        _ pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        // Decided from the types alone: no pixels are read in this process. The
        // copy WAS an image, so it never falls through to the text branch,
        // whether or not the helper finds it worth keeping (too big, say).
        guard ClipboardImagePasteboard.mayHoldImage(pasteboard, types: types) else {
            return false
        }

        let source = NSWorkspace.shared.frontmostApplication
        let capturedAt = Date()
        let fallbackLabel = ClipboardImagePasteboard.label(
            forSourceNamed: source?.localizedName, capturedAt: capturedAt)
        let appBundleID = source?.bundleIdentifier
        let changeCount = pasteboard.changeCount
        let generation = historyGeneration
        let limits = storedLimits
        enqueueWrite { [weak self] in
            let recorded = await ClipboardWriter.shared.recordImage(
                changeCount: changeCount, appBundleID: appBundleID, fallbackLabel: fallbackLabel,
                limits: limits)
            guard let self, let recorded else { return }
            guard await generation == self.historyGeneration else {
                // Cleared while in flight: forget it on disk too, or the clip
                // the user erased comes back with its file.
                await ClipboardWriter.shared.delete(id: recorded.storeID)
                return
            }
            await self.prependImage(
                ClipboardImageEntry(
                    label: recorded.label,
                    hash: recorded.stored.hash,
                    capturedAt: capturedAt,
                    firstCapturedAt: capturedAt,
                    copyCount: 1,
                    pixelSize: recorded.stored.pixelSize,
                    byteSize: recorded.stored.byteSize,
                    appBundleID: appBundleID,
                    storeID: recorded.storeID))
        }
        return true
    }

    /// Drops any older row for the same pixels: the store dedupes by hash, so
    /// two rows here would be one row on disk.
    private func prependImage(_ entry: ClipboardImageEntry) {
        var entry = entry
        if let existing = imageEntries.first(where: { $0.hash == entry.hash }) {
            // A re-copy: same first copy time and app as before, one more copy.
            entry = ClipboardImageEntry(
                label: entry.label, hash: entry.hash, capturedAt: entry.capturedAt,
                firstCapturedAt: existing.firstCapturedAt, copyCount: existing.copyCount + 1,
                pixelSize: entry.pixelSize, byteSize: entry.byteSize,
                appBundleID: entry.appBundleID ?? existing.appBundleID, storeID: entry.storeID,
                isPinned: existing.isPinned)
        }
        imageEntries.removeAll { $0.hash == entry.hash }
        imageEntries.insert(entry, at: 0)
        Self.trim(&imageEntries, to: maxImageEntries, isPinned: \.isPinned)
    }

    /// The app in front when something was copied. Lumio itself doesn't count (re-copying a clip
    /// from the launcher): nil keeps the app the clip first came from.
    private static func sourceAppBundleID() -> String? {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return app == Bundle.main.bundleIdentifier ? nil : app
    }

    func searchImages(_ term: String) -> [ClipboardImageEntry] {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return imageEntries }
        return imageEntries.filter { $0.label.localizedCaseInsensitiveContains(normalized) }
    }

    func deleteImageEntry(id: String) {
        let storeIDs = imageEntries.filter { $0.id == id }.compactMap(\.storeID)
        imageEntries.removeAll { $0.id == id }
        guard !storeIDs.isEmpty else { return }
        // Core unlinks the file with the row: the pixels are what was deleted.
        enqueueWrite {
            for storeID in storeIDs { await ClipboardWriter.shared.delete(id: storeID) }
        }
    }

    /// Both pixels and a file, so it pastes into an editor and into Finder
    /// alike. Marks the change seen so the poller skips Lumio's own write.
    /// The stored PNG bytes go on the pasteboard as they are: handing it an
    /// NSImage made AppKit decode the whole image to TIFF in this process.
    @discardableResult
    func copyImage(entry: ClipboardImageEntry) -> Bool {
        guard let url = entry.fileURL, let png = try? Data(contentsOf: url) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setString(url.absoluteString, forType: .fileURL)
        let wrote = pasteboard.writeObjects([item])
        lastChangeCount = pasteboard.changeCount
        // The poller skips this write, so move the clip to the top here.
        if wrote, let index = imageEntries.firstIndex(where: { $0.hash == entry.hash }) {
            let old = imageEntries.remove(at: index)
            imageEntries.insert(
                ClipboardImageEntry(
                    label: old.label, hash: old.hash, capturedAt: Date(),
                    firstCapturedAt: old.firstCapturedAt, copyCount: old.copyCount + 1,
                    pixelSize: old.pixelSize, byteSize: old.byteSize,
                    appBundleID: old.appBundleID, storeID: old.storeID,
                    isPinned: old.isPinned),
                at: 0)
        }
        return wrote
    }

    /// The `org.nspasteboard.*` convention: apps mark clips that history tools
    /// must not keep. Concealed is a secret (password managers), transient is
    /// a fleeting intermediate, auto-generated was not typed by the user.
    private static let concealedMarkers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    private func typesAreConcealed(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains { Self.concealedMarkers.contains($0.rawValue) }
    }

    private func typesCarryFileReference(
        _ types: [NSPasteboard.PasteboardType], _ pasteboard: NSPasteboard
    ) -> Bool {
        if types.contains(.fileURL) { return true }
        if types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")) { return true }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return true
        }
        return false
    }

    private func startBurstCaptureWindow() {
        remainingBurstSamples = AppConstants.Launcher.Clipboard.burstSampleCount
        if burstTimer != nil {
            return
        }

        burstTimer = Timer.scheduledTimer(
            withTimeInterval: AppConstants.Launcher.Clipboard.burstPollInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                if self.remainingBurstSamples <= 0 {
                    self.burstTimer?.invalidate()
                    self.burstTimer = nil
                    return
                }

                self.remainingBurstSamples -= 1
                self.captureLatestClipboardIfNeeded()
            }
        }

        if let burstTimer {
            RunLoop.main.add(burstTimer, forMode: .common)
        }
    }
}
