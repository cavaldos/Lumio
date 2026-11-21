import Foundation

/// The round buttons that split off the idle launcher bar: which feature each of the fixed
/// slots opens, in order, saved as `quick_bubbles=app,folder,doc,content`.
/// Codes are `SpotlightKind` raw values. Pure logic, so it is unit tested (LauncherLogicTests).
nonisolated enum QuickBubbles {
    static let configKey = "quick_bubbles"

    /// The window and the idle bar are sized for exactly this many buttons.
    static let slotCount = 4

    /// Every feature a button can open: the result groups, then the tool tabs.
    static let choices = ["app", "folder", "doc", "content", "clip", "lookup", "translation", "process"]

    static let defaultCodes = ["app", "folder", "doc", "content"]

    /// Exactly `slotCount` known, distinct codes: junk and repeats are dropped, then empty slots
    /// are filled from the defaults (then the other choices) that are not used yet.
    static func normalized(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var out = codes
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { choices.contains($0) && seen.insert($0).inserted }
        out = Array(out.prefix(slotCount))
        for code in defaultCodes + choices where out.count < slotCount && !out.contains(code) {
            out.append(code)
        }
        return out
    }

    static func parse(_ raw: String) -> [String] {
        normalized(raw.split(separator: ",").map(String.init))
    }

    static func render(_ codes: [String]) -> String {
        normalized(codes).joined(separator: ",")
    }

    /// Slot `slot` set to `code`. If another slot already has it, the two swap.
    static func setting(slot: Int, to code: String, in codes: [String]) -> [String] {
        var out = normalized(codes)
        guard out.indices.contains(slot), choices.contains(code) else { return out }
        if let other = out.firstIndex(of: code) { out.swapAt(slot, other) } else { out[slot] = code }
        return out
    }

    /// Slot `slot` moved `offset` places (-1 = left), clamped at both ends.
    static func moving(slot: Int, by offset: Int, in codes: [String]) -> [String] {
        var out = normalized(codes)
        guard out.indices.contains(slot) else { return out }
        let to = min(max(slot + offset, 0), out.count - 1)
        out.swapAt(slot, to)
        return out
    }
}
