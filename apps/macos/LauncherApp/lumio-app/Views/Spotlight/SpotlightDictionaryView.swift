//
//  SpotlightDictionaryView.swift
//  lumio-app
//
//  tw" — right half of the panel. The selected word's entries laid out like Dictionary.app
//  (headword | pronunciation |, parts of speech, senses, examples), with the word's
//  Translations (languages chosen in Settings) in a bar along the bottom.
//
//  Painted with system colors, like the rest of the Spotlight preview.
//

import SwiftUI

struct SpotlightDictionaryView: View {
    let word: String
    /// A linked word in an entry was clicked: look that word up.
    var onLookup: (String) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    /// Built page; nil while loading, "" when no dictionary has the word.
    @State private var page: String?
    /// nil while translating.
    @State private var translations: [SpotlightTranslation]?

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
                .padding(.horizontal, 12)
            bottomBar
        }
        .task(id: isDark) { await load() }
    }

    // MARK: - Content

    @ViewBuilder
    private var main: some View {
        if let page, !page.isEmpty {
            DictionaryEntryWebView(
                html: page,
                isDark: isDark,
                onSpeak: LookupActions.speak,
                onOpenWord: onLookup
            )
            .padding(.leading, 18)
            .padding(.top, 12)
        } else if page != nil {
            noEntry
        }
    }

    /// No dictionary has the word (often a phrase): show it with its translations in full.
    private var noEntry: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(word)
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                    Text("No dictionary entry")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                if let translations {
                    ForEach(translations) { translation in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(translation.label.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(.tertiary)
                            Text(translation.text ?? "No translation")
                                .font(.system(size: 16, design: .serif))
                                .foregroundStyle(translation.text == nil ? .tertiary : .primary)
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.never)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            // The page already shows the translations in full when there is no entry.
            if page?.isEmpty == false {
                if let translations {
                    ForEach(translations) { translationChip($0) }
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            Spacer(minLength: 4)
            iconButton("speaker.wave.2.fill", help: "Speak") { LookupActions.speak(word) }
            iconButton("book", help: "Open in Dictionary") { LookupActions.openInDictionary(word) }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    /// "EN confer" — click to hear it.
    private func translationChip(_ translation: SpotlightTranslation) -> some View {
        Button {
            if let text = translation.text { LookupActions.speak(text) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(translation.code)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(translation.text ?? "—")
                    .font(.system(size: 13))
                    .foregroundStyle(translation.text == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(translation.text ?? "No translation")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Loading

    private func load() async {
        // Dictionary records are local (a few ms): show them right away.
        let entries = SpotlightLookupCache.entries(for: word)
        page = entries.isEmpty ? "" : LookupHTML.entriesDocument(entries, style: Self.style(dark: isDark))

        if let cached = SpotlightLookupCache.translations(for: word) {
            translations = cached
            return
        }
        // Translation is a network call: wait for the selection to settle (arrowing through rows).
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let result = await SpotlightModeRows.fetchTranslations(word)
        guard !Task.isCancelled else { return }
        SpotlightLookupCache.store(result, for: word)
        translations = result
    }

    private static func style(dark: Bool) -> LookupHTML.Style {
        let ink = dark ? "255, 255, 255" : "0, 0, 0"
        return LookupHTML.Style(
            text: "rgba(\(ink), 0.9)",
            secondary: "rgba(\(ink), 0.62)",
            muted: "rgba(\(ink), 0.45)",
            divider: "rgba(\(ink), 0.12)",
            fontSize: 15,
            isDark: dark
        )
    }
}

/// One of the word's translations (tw").
struct SpotlightTranslation: Identifiable, Equatable {
    let label: String
    /// Short label shown in the bar: EN, VI, JA.
    let code: String
    /// nil when the translation failed.
    let text: String?

    var id: String { code }
}

/// Keeps lookups for the words already seen in this session, so moving back and forth
/// through the list doesn't translate the same word again.
enum SpotlightLookupCache {
    private static let limit = 60
    private static var entryCache: [String: [DictionaryEntry]] = [:]
    private static var translationCache: [String: [SpotlightTranslation]] = [:]

    static func translations(for word: String) -> [SpotlightTranslation]? {
        translationCache[word]
    }

    static func store(_ translations: [SpotlightTranslation], for word: String) {
        if translationCache.count > limit { translationCache = [:] }
        translationCache[word] = translations
    }

    /// Drops the dictionary HTML (the heavy part) when the launcher hides.
    /// Rebuilding it is a local lookup of a few ms. Translations stay: they
    /// are small, and fetching them again is a network call.
    static func purgeEntries() {
        entryCache.removeAll()
    }

    static func entries(for word: String) -> [DictionaryEntry] {
        if let cached = entryCache[word] { return cached }
        if entryCache.count > limit { entryCache = [:] }
        let entries = DictionaryLookupService.entries(for: word)
        entryCache[word] = entries
        return entries
    }
}
