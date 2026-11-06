import AppKit
import Carbon

/// What a global shortcut does. Saved as `hotkey_<rawValue>=cmd+shift+v` in the config
/// (empty value = off). The tab actions use `SpotlightKind` raw values.
nonisolated enum HotKeyAction: String, CaseIterable, Identifiable, Sendable {
    case launcher, settings, clip, lookup, translation, process, content

    var id: String { rawValue }

    var title: String {
        switch self {
        case .launcher: "Open Lumio"
        case .settings: "Settings"
        case .clip: "Clipboard"
        case .lookup: "Dictionary"
        case .translation: "Translate"
        case .process: "Processes"
        case .content: "OCR"
        }
    }

    var detail: String {
        switch self {
        case .launcher: "Show or hide the launcher"
        case .settings: "Open this window"
        case .clip: "Open the launcher on clipboard history"
        case .lookup: "Look up the selected text, or open Dictionary"
        case .translation: "Translate the selected text, or open Translate"
        case .process: "Open the launcher on running processes"
        case .content: "Search text in images & PDFs"
        }
    }

    var configKey: String { "hotkey_\(rawValue)" }

    /// Option+Space and Cmd+Shift+Space, as before; the tab shortcuts start off.
    var defaultValue: String {
        switch self {
        case .launcher: "opt+space"
        case .settings: "cmd+shift+space"
        default: ""
        }
    }

    static var defaultValues: [String: String] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.defaultValue) })
    }

    static func named(configKey key: String) -> HotKeyAction? {
        allCases.first { $0.configKey == key }
    }
}

/// One key plus modifiers. Written to the config as `cmd+shift+v`, shown as `⇧⌘V`.
nonisolated struct KeyCombo: Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags

    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
    }

    /// The combo a key press makes. nil for keys with no name here (e.g. a lone modifier).
    init?(event: NSEvent) {
        let code = UInt32(event.keyCode)
        guard Self.key(for: code) != nil else { return nil }
        self.init(keyCode: code, modifiers: event.modifierFlags)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    /// Whether this key press is this combo (caps lock, fn, … ignored).
    func matches(keyCode code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        UInt32(code) == keyCode && flags.intersection(Self.relevantModifiers) == modifiers
    }

    /// A global shortcut needs ⌘, ⌥ or ⌃ (or is an F-key), or it would steal normal typing.
    var isUsableGlobally: Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty || Self.functionKeys.contains(keyCode)
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// `⌃⌥⇧⌘Space`, in the order macOS menus use.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.key(for: keyCode)?.symbol ?? "?")
    }

    /// `ctrl+opt+shift+cmd+space`.
    var configValue: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(Self.key(for: keyCode)?.name ?? "?")
        return parts.joined(separator: "+")
    }

    /// Reads `cmd+shift+v` (any order, case-insensitive). nil = empty or not understood.
    static func parse(_ raw: String) -> KeyCombo? {
        let parts = raw.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let key = keys.first(where: { $0.name == keyName }) else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        return KeyCombo(keyCode: key.code, modifiers: modifiers)
    }

    // MARK: - Key names

    private static func key(for code: UInt32) -> (name: String, symbol: String)? {
        keys.first { $0.code == code }.map { ($0.name, $0.symbol) }
    }

    private static let functionKeys: Set<UInt32> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].map(UInt32.init))

    private static let keys: [(code: UInt32, name: String, symbol: String)] = {
        var list: [(Int, String, String)] = [
            (kVK_ANSI_A, "a", "A"), (kVK_ANSI_B, "b", "B"), (kVK_ANSI_C, "c", "C"), (kVK_ANSI_D, "d", "D"),
            (kVK_ANSI_E, "e", "E"), (kVK_ANSI_F, "f", "F"), (kVK_ANSI_G, "g", "G"), (kVK_ANSI_H, "h", "H"),
            (kVK_ANSI_I, "i", "I"), (kVK_ANSI_J, "j", "J"), (kVK_ANSI_K, "k", "K"), (kVK_ANSI_L, "l", "L"),
            (kVK_ANSI_M, "m", "M"), (kVK_ANSI_N, "n", "N"), (kVK_ANSI_O, "o", "O"), (kVK_ANSI_P, "p", "P"),
            (kVK_ANSI_Q, "q", "Q"), (kVK_ANSI_R, "r", "R"), (kVK_ANSI_S, "s", "S"), (kVK_ANSI_T, "t", "T"),
            (kVK_ANSI_U, "u", "U"), (kVK_ANSI_V, "v", "V"), (kVK_ANSI_W, "w", "W"), (kVK_ANSI_X, "x", "X"),
            (kVK_ANSI_Y, "y", "Y"), (kVK_ANSI_Z, "z", "Z"),
            (kVK_ANSI_0, "0", "0"), (kVK_ANSI_1, "1", "1"), (kVK_ANSI_2, "2", "2"), (kVK_ANSI_3, "3", "3"),
            (kVK_ANSI_4, "4", "4"), (kVK_ANSI_5, "5", "5"), (kVK_ANSI_6, "6", "6"), (kVK_ANSI_7, "7", "7"),
            (kVK_ANSI_8, "8", "8"), (kVK_ANSI_9, "9", "9"),
            (kVK_Space, "space", "Space"), (kVK_Return, "return", "↩"), (kVK_Tab, "tab", "⇥"),
            (kVK_Delete, "delete", "⌫"), (kVK_Escape, "escape", "⎋"),
            (kVK_LeftArrow, "left", "←"), (kVK_RightArrow, "right", "→"),
            (kVK_UpArrow, "up", "↑"), (kVK_DownArrow, "down", "↓"),
            (kVK_ANSI_Minus, "minus", "-"), (kVK_ANSI_Equal, "equal", "="),
            (kVK_ANSI_LeftBracket, "leftbracket", "["), (kVK_ANSI_RightBracket, "rightbracket", "]"),
            (kVK_ANSI_Backslash, "backslash", "\\"), (kVK_ANSI_Semicolon, "semicolon", ";"),
            (kVK_ANSI_Quote, "quote", "'"), (kVK_ANSI_Comma, "comma", ","),
            (kVK_ANSI_Period, "period", "."), (kVK_ANSI_Slash, "slash", "/"),
            (kVK_ANSI_Grave, "grave", "`"),
        ]
        let fKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in fKeys.enumerated() {
            list.append((code, "f\(index + 1)", "F\(index + 1)"))
        }
        return list.map { (UInt32($0.0), $0.1, $0.2) }
    }()
}
