import AVFoundation
import AppKit

/// Speak / open-in-Dictionary, shared by the launcher's and Spotlight's lookup views.
enum LookupActions {
    private static let speechSynthesizer = AVSpeechSynthesizer()

    static func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = 0.46

        // Detected language first: the character checks below can't tell French "é" from Vietnamese.
        if let detected = TextTranslator.detectLanguage(of: trimmed, likely: TranslationLanguage.all),
           let voice = AVSpeechSynthesisVoice(language: detected.minimalIdentifier) {
            utterance.voice = voice
        } else if isJapaneseText(trimmed) {
            utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        } else if isVietnameseText(trimmed) {
            utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
        } else if let englishVoice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = englishVoice
        } else if let preferred = Locale.preferredLanguages.first,
                  let localeVoice = AVSpeechSynthesisVoice(language: preferred) {
            utterance.voice = localeVoice
        }

        speechSynthesizer.speak(utterance)
    }

    private static func isJapaneseText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }

    private static func isVietnameseText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x00C0...0x00FF).contains(v) || (0x0100...0x017F).contains(v) || (0x1EA0...0x1EF9).contains(v) {
                return true
            }
        }
        return false
    }

    static func openInDictionary(_ word: String) {
        NSWorkspace.shared.open(URL(string: "dict:///\(word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word)")!)
    }
}
