import Foundation

/// One documented shortcut.
///
/// `id` is the stable handle a future user remapping binds an override to: the
/// displayed `keys` may change, the id must not. Entries carry one even though
/// nothing overrides them yet, because adding remapping later must not have to
/// invent identifiers for shortcuts people already learned.
struct ShortcutEntry: Identifiable {
    let id: String
    let keys: String
    let action: String
    /// False when there is no chord to reassign - a typed prefix, a positional
    /// `Cmd+N` derived from catalog order, or a pointer affordance. A remapping
    /// UI offers only the remappable ones, so it never presents a row that
    /// cannot be honoured.
    var remappable: Bool = true

    init(_ id: String, _ keys: String, _ action: String, remappable: Bool = true) {
        self.id = id
        self.keys = keys
        self.action = action
        self.remappable = remappable
    }
}

/// The filter capsules on the help screen. Settings renders every topic in this
/// order, so "all shortcuts" and "the Shortcuts tab" are the same list.
enum ShortcutTopic: String, CaseIterable, Identifiable {
    case main
    case prefixes
    case command

    var id: String { rawValue }

    var label: String {
        switch self {
        case .main: return "Main"
        case .prefixes: return "Prefixes"
        case .command: return "Command"
        }
    }
}

/// One titled block. The title is the identity: two groups never share one.
struct ShortcutGroup: Identifiable {
    let title: String
    let topic: ShortcutTopic
    let entries: [ShortcutEntry]
    var id: String { title }
}

/// The single source of truth for keyboard documentation.
///
/// Both surfaces read this: the in-window help screen (`Cmd+H`, filtered by
/// topic) and Settings > Shortcuts (flat, every group). They used to be two
/// hand-maintained tables, which drifted - six rows were duplicated verbatim,
/// the AI keys existed only in help, and the `Cmd+N` command list in Settings
/// had gone stale enough to name the wrong command.
enum ShortcutCatalog {
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Main", topic: .main, entries: [
            ShortcutEntry("main.open", "Enter", "Open selected app/file/folder or copy selected clipboard item"),
            ShortcutEntry("main.copy", "Cmd+C", "Copy selected file/folder to pasteboard"),
            ShortcutEntry("main.pick", "Cmd+P", "Toggle pick on selected file/folder (multi-select copy)"),
            ShortcutEntry("main.openPicked", "Shift+Enter", "Open all picked files/folders at once"),
            ShortcutEntry("main.clearPicks", "Cmd+Shift+P", "Clear all picked items"),
            ShortcutEntry("main.trash", "Cmd+D", "Trash selected file/folder (Trash pin: empty it) or remove the clipboard item"),
            ShortcutEntry("main.actions", "Cmd+K / Ctrl+K", "Open the action menu for the selected row (Cmd+J/K or Ctrl+J/K move, Enter runs)"),
            ShortcutEntry("main.moveTab", "Tab / Shift+Tab", "Move selection"),
            ShortcutEntry("main.moveArrows", "Up / Down", "Move selection"),
            ShortcutEntry("main.reveal", "Cmd+F", "Reveal selected app/file/folder in Finder"),
            ShortcutEntry("main.edit", "Cmd+E", "Open selected file/folder in your editor (set text_editor / code_editor)"),
            ShortcutEntry("main.terminal", "Cmd+T", "Open a terminal there (set terminal); switches theme when no row is selected"),
            ShortcutEntry("main.webSearch", "Cmd+Enter", "Search current query on Google"),
            ShortcutEntry("main.commandMode", "Cmd+/", "Enter command mode"),
            ShortcutEntry("main.commandJump", ":cmd", "Jump to a command from home (e.g. :kill chrome, :speed)", remappable: false),
            ShortcutEntry("main.hideApp", "Cmd+Shift+H", "Hide the selected app from Lumio"),
            ShortcutEntry("main.help", "Cmd+H", "Toggle this help screen"),
            ShortcutEntry("main.back", "Esc", "Back / close (context dependent)"),
            ShortcutEntry("main.hideLauncher", "Shift+Esc", "Hide launcher"),
        ]),


        ShortcutGroup(title: "Clipboard history", topic: .main, entries: [
            ShortcutEntry("clipboard.copyBack", "Enter", "Copy selected history item back to clipboard"),
            ShortcutEntry("clipboard.remove", "Cmd+D", "Remove selected clipboard item from Lumio history"),
        ]),

        ShortcutGroup(title: "View & panels", topic: .main, entries: [
            ShortcutEntry("view.settings", "Cmd+Shift+,", "Open/close settings panel"),
            ShortcutEntry("view.reloadConfig", "Cmd+Shift+;", "Reload .lumio/config"),
            ShortcutEntry("view.zoom", "Cmd+- / Cmd+=", "Zoom UI scale out / in"),
            ShortcutEntry("view.zoomReset", "Cmd+0", "Reset UI scale (opens the tenth session while the AI list is up)"),
        ]),


        ShortcutGroup(title: "Query prefixes", topic: .prefixes, entries: prefixEntries),

        ShortcutGroup(title: "Command mode", topic: .command, entries: [commandSwitchEntry] + [
            ShortcutEntry("command.switchTab", "Tab / Shift+Tab", "Switch command"),
            ShortcutEntry("command.byPort", "3000", "Find process by port or PID", remappable: false),
            ShortcutEntry("command.killSelect", "Up / Down", "Select app in kill results"),
            ShortcutEntry("command.killConfirm", "Y / N", "Confirm/cancel kill action"),
            ShortcutEntry("command.back", "Esc", "Back to the app list"),
        ]),

        ShortcutGroup(title: "Speed panel", topic: .command, entries: [
            ShortcutEntry("speed.rerun", "R", "Run the test again inside /speed"),
            ShortcutEntry("speed.revealAddress", "E", "Show or hide the public address inside /speed"),
        ]),
    ]

    /// Groups for one topic, in reading order.
    static func groups(for topic: ShortcutTopic) -> [ShortcutGroup] {
        groups.filter { $0.topic == topic }
    }

    static var allEntries: [ShortcutEntry] { groups.flatMap(\.entries) }

    /// Derived from the canonical prefix list so the help screen, the Shortcuts
    /// tab, and the `"` discovery menu cannot drift.
    private static var prefixEntries: [ShortcutEntry] {
        AppConstants.Launcher.PrefixSuggestion.all.map { entry in
            ShortcutEntry("prefix.\(entry.prefix)", entry.displayWithArg, entry.description, remappable: false)
        }
    }

    /// Derived from `commandCatalog`, whose ORDER is the mapping: ⌘N selects the
    /// Nth entry. Writing this list by hand is what let Settings claim ⌘4 was
    /// `/kill` after `/speed` was inserted ahead of it. Not remappable for the
    /// same reason - the binding is positional, so reordering the catalog is the
    /// only way to change it.
    private static var commandSwitchEntry: ShortcutEntry {
        let commands = AppConstants.Launcher.commandCatalog
        let names = commands.map { "/\($0.id)" }.joined(separator: ", ")
        let keys = commands.isEmpty ? "Cmd+1" : "Cmd+1..\(commands.count)"
        return ShortcutEntry("command.switchByIndex", keys, "Switch directly to \(names)", remappable: false)
    }
}
