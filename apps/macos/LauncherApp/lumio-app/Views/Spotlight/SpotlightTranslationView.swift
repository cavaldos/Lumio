//
//  SpotlightTranslationView.swift
//  lumio-app
//
//  tr" — right half of the panel: the typed text (with its detected language) above its
//  translation into the selected row's language, then a bar with the engine, Speak and Copy.
//
//  Painted with system colors, like the rest of the Spotlight preview.
//

import AppKit
import SwiftUI

/// tr" — translations of the typed text, shared by the rows and the preview.
struct SpotlightTranslationBatch: Equatable {
    /// Text being translated (the latest typed).
    var text = ""
    /// Detected language of `text` ("Vietnamese"), nil when it couldn't be told.
    var sourceName: String?
    /// Target code → translation. While a new text is translating this still holds the previous
    /// text's results (shown dimmed), so the rows don't flash empty on every keystroke.
    var results: [String: TextTranslation] = [:]
    var isTranslating = false

    func result(for code: String?) -> TextTranslation? {
        code.flatMap { results[$0] }
    }

    /// Finished, and this language got nothing back.
    func failed(_ code: String?) -> Bool {
        !isTranslating && result(for: code) == nil
    }
}

struct SpotlightTranslationView: View {
    let batch: SpotlightTranslationBatch
    let target: TranslationLanguage

    @State private var copied = false

    private var result: TextTranslation? { batch.result(for: target.code) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(batch.sourceName.map { "\($0) · detected" } ?? "Detected language") {
                        Text(batch.text)
                            .font(.system(size: 14.5))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    section(target.name) { translation }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
                .padding(.horizontal, 12)
            bottomBar
        }
    }

    @ViewBuilder
    private var translation: some View {
        if let result {
            Text(result.text)
                .font(.system(size: result.text.count > 160 ? 16 : 21, weight: .medium))
                .opacity(batch.isTranslating ? 0.5 : 1)
                .animation(.easeOut(duration: 0.15), value: batch.isTranslating)
        } else if batch.isTranslating {
            ProgressView().controlSize(.small)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't translate")
                    .font(.system(size: 15, weight: .medium))
                Text("Download \(target.name) in System Settings ▸ General ▸ Language & Region ▸ Translation Languages to translate on-device.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if let result {
                engineLabel(result.engine)
            }
            Spacer(minLength: 4)
            iconButton("speaker.wave.2.fill", help: "Speak") {
                if let text = result?.text { LookupActions.speak(text) }
            }
            iconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy translation") { copy() }
        }
        .disabled(result == nil)
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    @ViewBuilder
    private func engineLabel(_ engine: TextTranslation.Engine) -> some View {
        let (symbol, text, help): (String, String, String) = switch engine {
        case .apple:
            ("apple.logo", "Apple Translation · on-device", "Translated on this Mac")
        case .google:
            ("globe", "Google Translate", "Online: \(target.name) or the source language isn't downloaded for Apple Translation")
        case .unchanged:
            ("equal", "Already \(target.name)", "The text is already in \(target.name)")
        }
        Label(text, systemImage: symbol)
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .help(help)
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

    private func copy() {
        guard let text = result?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}
