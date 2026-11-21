import Foundation

/// One translation and the engine that produced it.
nonisolated struct TextTranslation: Equatable, Sendable {
    enum Engine: Equatable, Sendable {
        /// Apple Translation, on-device.
        case apple
        /// Google, online (fallback).
        case google
        /// Already in the target language: the text as typed.
        case unchanged
    }

    let text: String
    let engine: Engine
}

/// Translations already fetched this session, keyed by source language, target and text.
/// Bounded and dropped oldest-first; small strings, so it is not purged when the launcher
/// hides (unlike the preview caches): fetching again costs an API call, not a few ms.
nonisolated final class TranslationCache: @unchecked Sendable {
    static let shared = TranslationCache()
    static let capacity = 300

    private struct Storage {
        var entries: [String: TextTranslation] = [:]
        /// Insertion order, oldest first, for eviction.
        var order: [String] = []
    }

    /// Guarded by `lock` (Mutex needs macOS 15; the logic package targets older).
    private var storage = Storage()
    private let lock = NSLock()
    private let capacity: Int

    init(capacity: Int = TranslationCache.capacity) {
        self.capacity = capacity
    }

    /// `sourceID`: the detected language (nil = unknown). It is part of the key: the same
    /// letters detected as another language translate differently.
    static func key(_ text: String, sourceID: String?, targetCode: String) -> String {
        "\(sourceID ?? "?")>\(targetCode)|\(text)"
    }

    func get(_ key: String) -> TextTranslation? {
        lock.withLock { storage.entries[key] }
    }

    func set(_ key: String, _ value: TextTranslation) {
        lock.withLock {
            if storage.entries.updateValue(value, forKey: key) == nil {
                storage.order.append(key)
            }
            while storage.order.count > capacity {
                storage.entries.removeValue(forKey: storage.order.removeFirst())
            }
        }
    }

    func removeAll() {
        lock.withLock { storage = Storage() }
    }
}
