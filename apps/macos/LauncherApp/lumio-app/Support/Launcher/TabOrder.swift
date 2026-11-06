import Foundation

/// Order of the launcher's tool tabs (OCR, Clipboard, Dictionary, Translate, Processes), as
/// chosen in Settings and saved as `tab_order=clip,lookup,translation,process,content`.
/// Codes are `SpotlightKind` raw values. Pure logic, so it is unit tested (LauncherLogicTests).
nonisolated enum TabOrder {
    static let configKey = "tab_order"

    /// Every reorderable tab, in the default order. OCR is last: it is the one tab that starts
    /// a background process (the OCR worker) when opened.
    static let defaultCodes = ["clip", "lookup", "translation", "process", "content"]

    /// A saved order made whole: unknown and repeated codes are dropped, and any tab the saved
    /// order is missing (one added by a newer build, or a hand-edited line) is appended in its
    /// default position, so no tab can disappear.
    static func normalized(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var out = codes
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { defaultCodes.contains($0) && seen.insert($0).inserted }
        out += defaultCodes.filter { !seen.contains($0) }
        return out
    }

    /// The config value, read back. Empty or unreadable gives the default order.
    static func parse(_ raw: String) -> [String] {
        normalized(raw.split(separator: ",").map(String.init))
    }

    static func render(_ codes: [String]) -> String {
        normalized(codes).joined(separator: ",")
    }

    /// `code` moved `offset` places (-1 = one to the left), clamped at both ends.
    static func moving(_ code: String, by offset: Int, in codes: [String]) -> [String] {
        var order = normalized(codes)
        guard let from = order.firstIndex(of: code) else { return order }
        let to = min(max(from + offset, 0), order.count - 1)
        guard to != from else { return order }
        order.remove(at: from)
        order.insert(code, at: to)
        return order
    }
}
