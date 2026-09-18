import AppKit
import CoreServices
import SwiftUI

extension LauncherView {
    struct TranslationResult {
        let translated: String?
        let dictionaryDefinition: LookupPresentation?
    }

    /// Dictionary lookup query (`tw"text`). Returns the lookup text, or nil.
    func extractTranslationQuery(from input: String) -> String? {
        let translateWord = AppConstants.Launcher.QueryPrefix.translateWord
        guard input.count >= translateWord.count,
            input.prefix(translateWord.count).lowercased() == translateWord
        else {
            return nil
        }
        let text = String(input.dropFirst(translateWord.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func handleLookupTranslation(text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            showBanner("Type text after tw\" to translate", style: .error, duration: 3.2)
            return
        }

        Task {
            let results = await fetchAllTranslations(for: normalized)
            await MainActor.run {
                lookupDefinition = LookupDefinition(
                    query: normalized,
                    sourceLabel: "Input",
                    sections: [
                        LookupTranslationSection(label: "English", translated: results.en.translated, dictionaryDefinition: results.en.dictionaryDefinition, failed: results.en.translated == nil),
                        LookupTranslationSection(label: "Tiếng Việt", translated: results.vi.translated, dictionaryDefinition: results.vi.dictionaryDefinition, failed: results.vi.translated == nil),
                        LookupTranslationSection(label: "日本語", translated: results.ja.translated, dictionaryDefinition: results.ja.dictionaryDefinition, failed: results.ja.translated == nil),
                    ]
                )
            }
        }
    }

    func previewLookupDefinition(for input: String) {
        lookupPreviewTask?.cancel()

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = extractTranslationQuery(from: trimmed) else {
            lookupDefinition = nil
            return
        }

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            lookupDefinition = nil
            return
        }

        let expectedQuery = trimmed
        lookupPreviewTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }

            let results = await fetchAllTranslations(for: normalizedText)

            guard !Task.isCancelled else { return }
            await MainActor.run {
                let latestQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard latestQuery == expectedQuery else { return }
                lookupDefinition = LookupDefinition(
                    query: normalizedText,
                    sourceLabel: "Input",
                    sections: [
                        LookupTranslationSection(label: "English", translated: results.en.translated, dictionaryDefinition: results.en.dictionaryDefinition, failed: results.en.translated == nil),
                        LookupTranslationSection(label: "Tiếng Việt", translated: results.vi.translated, dictionaryDefinition: results.vi.dictionaryDefinition, failed: results.vi.translated == nil),
                        LookupTranslationSection(label: "日本語", translated: results.ja.translated, dictionaryDefinition: results.ja.dictionaryDefinition, failed: results.ja.translated == nil),
                    ]
                )
            }
        }
    }

    func fetchAllTranslations(for text: String) async -> (en: TranslationResult, vi: TranslationResult, ja: TranslationResult) {
        await withTaskGroup(of: (String, TranslationResult).self) { group in
            group.addTask {
                let translated = self.bridge.translate(text: text, targetLang: "en")?.translated
                let definition = await MainActor.run {
                    translated.flatMap { DictionaryParser.parse(self.fetchRawDefinition(for: $0) ?? "") }
                }
                return ("en", TranslationResult(translated: translated, dictionaryDefinition: definition))
            }
            group.addTask {
                let translated = self.bridge.translate(text: text, targetLang: "vi")?.translated
                let definition = await MainActor.run {
                    translated.flatMap { DictionaryParser.parse(self.fetchRawDefinition(for: $0) ?? "") }
                }
                return ("vi", TranslationResult(translated: translated, dictionaryDefinition: definition))
            }
            group.addTask {
                let translated = self.bridge.translate(text: text, targetLang: "ja")?.translated
                let definition = await MainActor.run {
                    translated.flatMap { DictionaryParser.parse(self.fetchRawDefinition(for: $0) ?? "") }
                }
                return ("ja", TranslationResult(translated: translated, dictionaryDefinition: definition))
            }

            var en = TranslationResult(translated: nil, dictionaryDefinition: nil)
            var vi = TranslationResult(translated: nil, dictionaryDefinition: nil)
            var ja = TranslationResult(translated: nil, dictionaryDefinition: nil)
            for await (lang, result) in group {
                switch lang {
                case "en": en = result
                case "vi": vi = result
                case "ja": ja = result
                default: break
                }
            }
            return (en, vi, ja)
        }
    }

    func fetchRawDefinition(for text: String) -> String? {
        let nsText = text as NSString
        let range = CFRange(location: 0, length: nsText.length)
        guard let unmanaged = DCSCopyTextDefinition(nil, text as CFString, range) else {
            return nil
        }
        let raw = (unmanaged.takeRetainedValue() as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}
