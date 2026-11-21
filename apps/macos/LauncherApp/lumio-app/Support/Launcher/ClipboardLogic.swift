import Foundation

/// The history limits a user can set, resolved the same way wherever they are read
/// (the clipboard store and the Settings window), so the two cannot disagree about
/// what a config line means.
nonisolated enum ClipboardLimits {
    typealias Text = AppConstants.Launcher.Clipboard
    typealias Image = AppConstants.Launcher.ClipboardImage

    static let textRange = Text.minEntries...Text.maxEntriesLimit
    static let imageRange = Image.minEntries...Image.maxEntriesLimit

    /// `clipboard_history_limit`, or the default when it is missing, unparseable or out
    /// of range.
    static func historyLimit(from values: [String: String]) -> Int {
        resolve(values[Text.historyLimitConfigKey], range: textRange, fallback: Text.maxEntries)
    }

    /// `clipboard_image_limit`: capped separately from text, and far lower - megabytes,
    /// not characters.
    static func imageLimit(from values: [String: String]) -> Int {
        resolve(values[Image.limitConfigKey], range: imageRange, fallback: Image.maxEntries)
    }

    /// An out-of-range limit is a typo, not a request, so the default stands rather than
    /// the nearest bound: clamping 5000 to 1000 looks like it worked.
    static func resolve(_ raw: String?, range: ClosedRange<Int>, fallback: Int) -> Int {
        guard let raw, let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return fallback
        }
        return range.contains(parsed) ? parsed : fallback
    }
}

/// What the in-memory history derives from a clip's text. All of it works from a
/// leading preview (plus the real size, known from the database), so a clip's full
/// text never has to stay resident to be listed.
nonisolated enum ClipboardText {
    /// The row label: newlines read as spaces, ends trimmed, long text elided.
    static func title(from text: String) -> String {
        let collapsed = normalizedNewlines(text)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty {
            return AppConstants.Launcher.Clipboard.emptyEntryTitle
        }
        let limit = AppConstants.Launcher.Clipboard.maxTitleCharacters
        if collapsed.count <= limit {
            return collapsed
        }
        return String(collapsed.prefix(limit)) + "…"
    }

    /// Blank lines count, and a single trailing newline does not add one. Mirrors the
    /// `line_count` core/storage reports for stored rows.
    static func lineCount(of text: String) -> Int {
        var normalized = normalizedNewlines(text)
        if normalized.hasSuffix("\n") {
            normalized.removeLast()
        }
        guard !normalized.isEmpty else { return 1 }
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// The leading part kept in memory. Leading whitespace is skipped, as the core does
    /// for stored rows, so a clip that opens with blank lines still has a title.
    static func preview(of text: String) -> String {
        String(
            text.drop(while: { $0.isWhitespace || $0.isNewline })
                .prefix(AppConstants.Launcher.Clipboard.previewCharacters))
    }

    /// CRLF and bare CR both read as one line break (terminal output carries CR).
    private static func normalizedNewlines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

/// The cheap identity a resident clip carries instead of its text: the core's own
/// dedupe hash (FNV-1a style over the trimmed UTF-8 bytes, see `content_hash` in
/// core/storage - same constants, including its non-standard multiplier), so a fresh copy is matched against rows loaded from the database
/// without comparing strings. A mismatch is harmless - the core dedupes on its side
/// anyway - it would only show a duplicate row until the next load.
nonisolated enum ClipboardContentKey {
    static func make(for text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.trimmingCharacters(in: .whitespacesAndNewlines).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
