//
//  TextTranslator.swift
//  lumio-app
//
//  Translates text with Apple's Translation framework: on-device, using the languages
//  downloaded in System Settings ▸ General ▸ Language & Region ▸ Translation Languages.
//  Falls back to the core's Google translate when Apple can't do it: macOS 15 (no
//  session outside SwiftUI there), a language that isn't downloaded, or a source
//  language that can't be detected.
//

import Foundation
import NaturalLanguage
import Translation

/// A language Lumio translates into (tr" rows, the tw" bar).
nonisolated struct TranslationLanguage: Hashable, Identifiable, Sendable {
    /// BCP-47 code: "en", "vi", "fr", "zh-Hans".
    let code: String
    let name: String

    var id: String { code }
    /// Short label: EN, VI, FR.
    var shortCode: String { (code.split(separator: "-").first.map(String.init) ?? code).uppercased() }
    var locale: Locale.Language { Locale.Language(identifier: code) }
    /// Code Google Translate expects (it wants "zh-CN" / "zh-TW", not the script form).
    var googleCode: String {
        switch code {
        case "zh-Hans": "zh-CN"
        case "zh-Hant": "zh-TW"
        default: code
        }
    }

    static let english = Self(code: "en", name: "English")
    static let vietnamese = Self(code: "vi", name: "Vietnamese")
    static let french = Self(code: "fr", name: "French")

    /// Every language that can be picked in Settings, in display order.
    static let supported: [Self] = [
        .english, .vietnamese, .french,
        Self(code: "ja", name: "Japanese"),
        Self(code: "ko", name: "Korean"),
        Self(code: "zh-Hans", name: "Chinese (Simplified)"),
        Self(code: "zh-Hant", name: "Chinese (Traditional)"),
        Self(code: "es", name: "Spanish"),
        Self(code: "de", name: "German"),
        Self(code: "it", name: "Italian"),
        Self(code: "pt", name: "Portuguese"),
        Self(code: "ru", name: "Russian"),
        Self(code: "th", name: "Thai"),
        Self(code: "id", name: "Indonesian"),
        Self(code: "hi", name: "Hindi"),
        Self(code: "ar", name: "Arabic"),
    ]

    /// Picked when the user hasn't chosen: Vietnamese, English, French.
    static let defaultCodes = ["vi", "en", "fr"]
    static let minSelected = 1
    static let maxSelected = 5

    /// The languages chosen in Settings, in display order.
    @MainActor static var all: [Self] { selected(ThemeStore.shared.settings.translationLanguages) }

    /// Known languages among `codes`, in display order, duplicates and unknown codes dropped.
    /// Falls back to the defaults when nothing usable is left.
    static func selected(_ codes: [String]) -> [Self] {
        let picked = supported.filter { codes.contains($0.code) }
        return picked.isEmpty ? supported.filter { defaultCodes.contains($0.code) } : picked
    }

    static func named(_ code: String?) -> Self? {
        supported.first { $0.code == code }
    }

    /// Same language as `other`, ignoring region; Chinese scripts count as different languages.
    func matches(_ other: Locale.Language) -> Bool {
        guard locale.languageCode == other.languageCode else { return false }
        guard locale.languageCode?.identifier == "zh" else { return true }
        return locale.script == nil || other.script == nil || locale.script == other.script
    }

    /// Targets for text written in `source`: every chosen language except the source itself.
    @MainActor static func targets(from source: Locale.Language?) -> [Self] {
        guard let source else { return all }
        return all.filter { !$0.matches(source) }
    }
}

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

nonisolated enum TextTranslator {
    /// Language of `text`, nil when it can't be told. Short text leans towards `likely`
    /// (the languages chosen in Settings, most likely first): a single word is ambiguous
    /// ("猫" is Chinese too, "sake" Norwegian).
    static func detectLanguage(of text: String, likely: [TranslationLanguage] = []) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        if text.split(whereSeparator: \.isWhitespace).count <= 2, !likely.isEmpty {
            var hints: [NLLanguage: Double] = [:]
            for (index, language) in likely.enumerated() {
                hints[NLLanguage(rawValue: language.code)] = Double(likely.count - index)
            }
            let total = hints.values.reduce(0, +)
            recognizer.languageHints = hints.mapValues { $0 / total }
        }
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// English name of a language: "Vietnamese".
    static func displayName(of language: Locale.Language) -> String {
        let id = language.minimalIdentifier
        return Locale(identifier: "en").localizedString(forIdentifier: id) ?? id
    }

    /// Translates `text` (written in `source`, nil = unknown) into `target`. nil when every engine failed.
    static func translate(
        _ text: String,
        from source: Locale.Language?,
        to target: TranslationLanguage
    ) async -> TextTranslation? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let source, target.matches(source) {
            return TextTranslation(text: text, engine: .unchanged)
        }
        if let source, let translated = await translateOnDevice(text, from: source, to: target.locale) {
            return TextTranslation(text: translated, engine: .apple)
        }
        guard !Task.isCancelled else { return nil }
        // The bridge call blocks on the network: keep it off the caller's thread.
        let online = await Task.detached(priority: .userInitiated) {
            EngineBridge.shared.translate(text: text, targetLang: target.googleCode)?.translated
        }.value
        guard let online = nonEmpty(online) else { return nil }
        return TextTranslation(text: online, engine: .google)
    }

    /// Apple Translation, only when both languages are already downloaded (never prompts).
    private static func translateOnDevice(
        _ text: String,
        from source: Locale.Language,
        to target: Locale.Language
    ) async -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        guard await LanguageAvailability().status(from: source, to: target) == .installed else { return nil }
        let session = TranslationSession(installedSource: source, target: target)
        do {
            return nonEmpty(try await session.translate(text).targetText)
        } catch {
            return nil
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
