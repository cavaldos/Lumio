import Foundation

/// Text rules shared by the content index and its search: folding, the FTS query, snippets
/// and which files get their text read. Pure logic, so it is unit tested (LauncherLogicTests).
nonisolated enum ContentSearchText {
    /// The trigram index can only match runs of 3+ characters.
    static let minQueryLength = 3

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp",
    ]
    static let pdfExtensions: Set<String> = ["pdf"]

    /// Only images and PDFs: the OCR tab is for text you can't otherwise search (text files
    /// like .md / .txt are left out on purpose).
    static func isIndexable(extension ext: String) -> Bool {
        let ext = ext.lowercased()
        return imageExtensions.contains(ext) || pdfExtensions.contains(ext)
    }

    // MARK: - Folding

    /// Lowercase, no diacritics, đ → d, every whitespace run → one space. Indexed text and
    /// queries go through the same fold, so "hoa don" finds "Hóa Đơn".
    static func fold(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for ch in text {
            if ch.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out += foldCharacter(ch)
        }
        return out
    }

    static func foldCharacter(_ ch: Character) -> String {
        if ch.isASCII { return ch.lowercased() }
        if ch == "đ" || ch == "Đ" { return "d" }
        return String(ch).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: - Query

    /// FTS5 MATCH expression for typed text: every word of 3+ characters must appear somewhere
    /// in the file (as a substring). nil when nothing is long enough to search.
    static func matchExpression(for query: String) -> String? {
        let words = fold(query).components(separatedBy: " ").filter { $0.count >= minQueryLength }
        guard !words.isEmpty else { return nil }
        return words
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
    }

    // MARK: - Snippet

    /// One line of `text` around the first place the query matches, with "…" where it was cut.
    /// Tries the whole query first, then its longest word. nil when neither appears.
    static func snippet(in text: String, query: String, radius: Int = 36) -> String? {
        let foldedQuery = fold(query)
        guard !foldedQuery.isEmpty else { return nil }

        // Fold character by character, remembering which original character each folded
        // scalar came from, so a match in the folded text maps back to the original.
        var original: [Character] = []
        var foldedScalars = String.UnicodeScalarView()
        var owner: [Int] = []
        var pendingSpace = false
        for ch in text {
            if ch.isWhitespace {
                pendingSpace = !original.isEmpty
                continue
            }
            if pendingSpace {
                original.append(" ")
                foldedScalars.append(" ")
                owner.append(original.count - 1)
                pendingSpace = false
            }
            original.append(ch)
            for scalar in foldCharacter(ch).unicodeScalars {
                foldedScalars.append(scalar)
                owner.append(original.count - 1)
            }
        }
        let folded = String(foldedScalars)

        let longestWord = foldedQuery.components(separatedBy: " ").max { $0.count < $1.count }
        let needles = [foldedQuery, longestWord].compactMap { $0 }.filter { $0.count >= 1 }
        guard let range = needles.lazy.compactMap({ folded.range(of: $0) }).first else { return nil }

        let scalars = folded.unicodeScalars
        let startScalar = scalars.distance(from: scalars.startIndex, to: range.lowerBound)
        let endScalar = scalars.distance(from: scalars.startIndex, to: range.upperBound)
        guard startScalar < owner.count, endScalar > 0 else { return nil }
        let matchStart = owner[startScalar]
        let matchEnd = owner[min(endScalar, owner.count) - 1] + 1

        let from = max(0, matchStart - radius)
        let to = min(original.count, matchEnd + radius)
        var line = String(original[from..<to]).trimmingCharacters(in: .whitespaces)
        if from > 0 { line = "…" + line }
        if to < original.count { line += "…" }
        return line
    }
}
