//
//  UsageLearning.swift
//  lumio-app
//
//  Learns what you pick, like Fluent Search's usage prioritization. Whatever you open for a
//  search is remembered together with the text you typed; next time you type something
//  similar it is offered first, instantly (it is stored, not searched for again). The more
//  often and the more recently you pick something, the higher it ranks.
//
//  The Rust core already learns for the apps and files in its own index; this covers
//  everything else Lumio lists (files from anywhere on the Mac, history pages, bookmarks,
//  links) and adds the "for THIS search" part.
//
//  Stored locally in ~/Library/Application Support/lumio/learned.json. Delete the file to
//  forget everything. Nothing leaves the Mac.
//

import Foundation

final class UsageLearning {
    static let shared = UsageLearning()

    private struct Entry: Codable {
        var kind: String
        var name: String
        var meta: String?
        var target: String
        var iconPath: String?
        var colors: String
        var symbol: String?
        var favicon: String?
        var candidateID: String?
        var count: Int
        var last: Date
        /// Typed text → how many times this was opened for it.
        var queries: [String: Int]
    }

    private var entries: [String: Entry] = [:]
    private var loaded = false
    private static let maxEntries = 600

    private static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("lumio/learned.json")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    private func save() {
        if entries.count > Self.maxEntries {
            let keep = entries.sorted { $0.value.last > $1.value.last }.prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        let snapshot = entries
        let file = Self.file
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Forgets everything learned (Settings ▸ Search ▸ Reset learning data).
    func reset() {
        loaded = true
        entries = [:]
        try? FileManager.default.removeItem(at: Self.file)
    }

    /// How many results it currently remembers.
    var count: Int {
        load()
        return entries.count
    }

    /// Kinds worth remembering: things with a stable target to open again.
    private static func storable(_ item: SpotlightItem) -> (kind: SpotlightKind, target: String)? {
        switch item.kind {
        case .app, .folder, .doc, .url:
            guard let target = item.target, !target.isEmpty else { return nil }
            return (item.kind, target)
        case .content:
            guard let target = item.target else { return nil }
            return (.doc, target)
        case .tab:
            // A tab's window/index is gone tomorrow; its address is not.
            guard let url = item.tab?.url ?? item.target else { return nil }
            return (.url, url)
        default:
            return nil
        }
    }

    /// Called when a row is opened from a normal search.
    func record(_ item: SpotlightItem, query: String) {
        guard let (kind, target) = Self.storable(item) else { return }
        load()
        let key = target.lowercased()
        let typed = Self.normalize(query)
        var entry = entries[key] ?? Entry(
            kind: kind.rawValue, name: item.name, meta: item.meta, target: target,
            iconPath: item.iconPath, colors: item.colors, symbol: item.symbol, favicon: item.favicon,
            candidateID: item.candidateID, count: 0, last: Date(), queries: [:]
        )
        entry.count += 1
        entry.last = Date()
        entry.name = item.name
        if typed.count >= 2 {
            entry.queries[typed, default: 0] += 1
            // Keep the texts that matter: the 12 most used.
            if entry.queries.count > 12 {
                entry.queries = Dictionary(uniqueKeysWithValues:
                    entry.queries.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) })
            }
        }
        entries[key] = entry
        save()
    }

    /// What you opened before for text like `query`, best first. Typing "moc" brings back what
    /// you picked for "mockup"; typing "mockup v2" brings back what you picked for "mockup".
    func picks(for query: String, limit: Int) -> [SpotlightItem] {
        load()
        let typed = Self.normalize(query)
        guard typed.count >= 2, !entries.isEmpty else { return [] }
        let scored: [(Entry, Double)] = entries.values.compactMap { entry in
            var hits = 0.0
            for (text, count) in entry.queries where text.hasPrefix(typed) || typed.hasPrefix(text) {
                // An exact repeat counts fully; a shared beginning counts by how much is shared.
                let shared = Double(min(text.count, typed.count)) / Double(max(text.count, typed.count))
                hits += Double(count) * (text == typed ? 1 : 0.5 + 0.5 * shared)
            }
            guard hits > 0 else { return nil }
            return (entry, hits * Self.decay(entry.last))
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .lazy
            .filter { !$0.0.target.hasPrefix("/") || FileManager.default.fileExists(atPath: $0.0.target) }
            .prefix(limit)
            .compactMap { entry, _ in Self.item(from: entry) }
    }

    /// How much you use `target` overall (0 = never), for ordering rows of equal match quality.
    func weight(forTarget target: String?) -> Double {
        guard let target else { return 0 }
        load()
        guard let entry = entries[target.lowercased()] else { return 0 }
        return Double(entry.count) * Self.decay(entry.last)
    }

    private static func item(from entry: Entry) -> SpotlightItem? {
        guard let kind = SpotlightKind(rawValue: entry.kind) else { return nil }
        let id: String = switch kind {
        case .url: "url|" + entry.target
        default: entry.candidateID ?? "learned|" + entry.target
        }
        return SpotlightItem(
            id: id, name: entry.name, kind: kind, colors: entry.colors, meta: entry.meta,
            target: entry.target, iconPath: entry.iconPath, symbol: entry.symbol,
            candidateID: entry.candidateID, favicon: entry.favicon
        )
    }

    /// Half as much weight every 30 days without use.
    private static func decay(_ date: Date) -> Double {
        pow(0.5, max(0, -date.timeIntervalSinceNow / 86_400) / 30)
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
