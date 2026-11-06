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
    /// BCP-47 code: "en", "vi", "ja".
    let code: String
    let name: String

    var id: String { code }
    /// Short label: EN, VI, JA.
    var shortCode: String { code.uppercased() }
    var locale: Locale.Language { Locale.Language(identifier: code) }

    static let english = Self(code: "en", name: "English")
    static let vietnamese = Self(code: "vi", name: "Vietnamese")
    static let japanese = Self(code: "ja", name: "Japanese")

    /// In display order.
    static let all: [Self] = [.english, .vietnamese, .japanese]

    static func named(_ code: String?) -> Self? {
        all.first { $0.code == code }
    }

    /// Targets for text written in `source`: every language except the source itself.
    static func targets(from source: Locale.Language?) -> [Self] {
        guard let code = source?.languageCode?.identifier else { return all }
        return all.filter { $0.code != code }
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
    /// Language of `text`, nil when it can't be told. Short text leans towards EN / VI / JA:
    /// a single word is ambiguous ("猫" is Chinese too, "sake" Norwegian).
    static func detectLanguage(of text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        if text.split(whereSeparator: \.isWhitespace).count <= 2 {
            recognizer.languageHints = [.english: 0.5, .vietnamese: 0.3, .japanese: 0.2]
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
        if let source, source.languageCode == target.locale.languageCode {
            return TextTranslation(text: text, engine: .unchanged)
        }
        if let source, let translated = await translateOnDevice(text, from: source, to: target.locale) {
            return TextTranslation(text: translated, engine: .apple)
        }
        guard !Task.isCancelled else { return nil }
        // The bridge call blocks on the network: keep it off the caller's thread.
        let online = await Task.detached(priority: .userInitiated) {
            EngineBridge.shared.translate(text: text, targetLang: target.code)?.translated
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
