import CoreServices
import Foundation

enum LauncherTranslationCommand {
    case lookup(String)
}

final class LauncherTranslationService: Sendable {
    private struct LookupTranslationResult {
        let translated: String?
        let dictionaryDefinition: LookupPresentation?
    }

    private let bridge: EngineBridge

    init(bridge: EngineBridge = .shared) {
        self.bridge = bridge
    }

    func extractCommand(from input: String) -> LauncherTranslationCommand? {
        guard input.count >= 3, input.prefix(3).lowercased() == "tw\"" else {
            return nil
        }
        let text = String(input.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : .lookup(text)
    }

    func fetchLookupDefinition(for text: String) async -> LookupDefinition {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = await fetchLookupTranslations(for: normalized)
        return LookupDefinition(
            query: normalized,
            sourceLabel: "Input",
            sections: [
                LookupTranslationSection(label: "English", translated: results.en.translated, dictionaryDefinition: results.en.dictionaryDefinition, failed: results.en.translated == nil),
                LookupTranslationSection(label: "Tiếng Việt", translated: results.vi.translated, dictionaryDefinition: results.vi.dictionaryDefinition, failed: results.vi.translated == nil),
                LookupTranslationSection(label: "日本語", translated: results.ja.translated, dictionaryDefinition: results.ja.dictionaryDefinition, failed: results.ja.translated == nil),
            ]
        )
    }

    private func fetchLookupTranslations(for text: String) async -> (en: LookupTranslationResult, vi: LookupTranslationResult, ja: LookupTranslationResult) {
        await withTaskGroup(of: (String, LookupTranslationResult).self) { group in
            group.addTask { @MainActor in
                let translated = self.bridge.translate(text: text, targetLang: "en")?.translated
                let definition = translated.flatMap { DictionaryParser.parse(self.fetchRawDefinition(for: $0) ?? "") }
                return ("en", LookupTranslationResult(translated: translated, dictionaryDefinition: definition))
            }
            group.addTask { @MainActor in
                let translated = self.bridge.translate(text: text, targetLang: "vi")?.translated
                let definition = translated.flatMap { DictionaryParser.parse(self.fetchRawDefinition(for: $0) ?? "") }
                return ("vi", LookupTranslationResult(translated: translated, dictionaryDefinition: definition))
            }
            group.addTask { @MainActor in
                let translated = self.bridge.translate(text: text, targetLang: "ja")?.translated
                let definition = translated.flatMap { DictionaryParser.parse(self.fetchRawDefinition(for: $0) ?? "") }
                return ("ja", LookupTranslationResult(translated: translated, dictionaryDefinition: definition))
            }

            var en = LookupTranslationResult(translated: nil, dictionaryDefinition: nil)
            var vi = LookupTranslationResult(translated: nil, dictionaryDefinition: nil)
            var ja = LookupTranslationResult(translated: nil, dictionaryDefinition: nil)
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

    private func fetchRawDefinition(for text: String) -> String? {
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
