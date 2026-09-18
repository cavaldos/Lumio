import AppKit
import Foundation
import OSLog

private typealias KeyCode = AppConstants.Launcher.KeyCode

@MainActor
final class KeyboardSelectionMonitor {
    private var monitor: Any?
    private var isKillConfirmationActive: @MainActor () -> Bool = { false }
    nonisolated private static let logger = Logger(subsystem: "noah-code.Lumio", category: "ui-key")
    nonisolated private static let debugKeyLoggingEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        let raw = env["LUMIO_UI_DEBUG_EVENTS"] ?? env["LUMIO_DEV_HINT"] ?? ""
        return ["1", "true", "yes", "on"].contains(
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }()

    nonisolated private static func logKey(_ message: String) {
        guard Self.debugKeyLoggingEnabled else { return }
        Self.logger.notice("\(message, privacy: .public)")
    }

    /// ⌘ and ⌃ are interchangeable for the action-menu J/K pair, so the same
    /// vim keys work whichever modifier the hand is already on. Exact match, so
    /// adding Shift or Option still falls through to whatever owns that chord.
    nonisolated private static func isActionMenuChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags == [.command] || flags == [.control]
    }

    func start(
        onNext: @escaping @MainActor () -> Void,
        onPrevious: @escaping @MainActor () -> Void,
        onArrowDown: (@MainActor () -> Void)? = nil,
        onArrowUp: (@MainActor () -> Void)? = nil,
        onRecallPrompt: (@MainActor (Bool) -> Bool)? = nil,
        onEnterCommandMode: @escaping @MainActor () -> Void,
        onExitCommandMode: @escaping @MainActor () -> Void,
        onHideLauncher: @escaping @MainActor () -> Void,
        inCommandMode: @escaping @MainActor () -> Bool,
        onWebSearch: @escaping @MainActor () -> Void,
        /// The Cmd+K action menu. While it is open it owns the arrows, Enter,
        /// and Escape, so those never reach the results list underneath.
        inActionMenu: @escaping @MainActor () -> Bool = { false },
        onToggleActionMenu: @escaping @MainActor () -> Void = {},
        onActionMenuMove: @escaping @MainActor (Int) -> Void = { _ in },
        onActionMenuRun: @escaping @MainActor () -> Void = {},
        onActionMenuClose: @escaping @MainActor () -> Void = {},
        onRevealInFinder: @escaping @MainActor () -> Void,
        /// Cmd+E / Cmd+T act through the user's declared tools.
        onEditSelection: @escaping @MainActor () -> Void = {},
        onOpenTerminalForSelection: @escaping @MainActor () -> Void = {},
        onCopySelection: @escaping @MainActor () -> Bool,
        onTogglePick: @escaping @MainActor () -> Void,
        onClearPicked: @escaping @MainActor () -> Void,
        onOpenAllPicked: @escaping @MainActor () -> Void = {},
        hasPickedItems: @escaping @MainActor () -> Bool = { false },
        onToggleHelp: @escaping @MainActor () -> Void,
        onDismissHelpIfVisible: @escaping @MainActor () -> Bool,
        onSelectCommandByIndex: @escaping @MainActor (Int) -> Void,
        onActivateRunningApp: @escaping @MainActor (Int) -> Bool = { _ in false },
        /// Escape inside a drill-down goes back one level. True means it did.
        onPopLevel: (@MainActor () -> Bool)? = nil,
        onEscapeHome: (@MainActor () -> Bool)? = nil,
        onConfirmKill: (@MainActor () -> Void)? = nil,
        onCancelKill: (@MainActor () -> Void)? = nil,
        killConfirmationActive: @escaping @MainActor () -> Bool = { false },
        onRequestDelete: (@MainActor () -> Void)? = nil,
        onConfirmDelete: (@MainActor () -> Void)? = nil,
        onCancelDelete: (@MainActor () -> Void)? = nil,
        deleteConfirmationActive: @escaping @MainActor () -> Bool = { false },
        onConfirmHideApp: (@MainActor () -> Void)? = nil,
        onCancelHideApp: (@MainActor () -> Void)? = nil,
        hideAppConfirmationActive: @escaping @MainActor () -> Bool = { false },
        onCancelAction: (@MainActor () -> Void)? = nil,
        actionConfirmationActive: @escaping @MainActor () -> Bool = { false },
        onUndoAction: (@MainActor () -> Bool)? = nil,
        onStopGeneration: (@MainActor () -> Bool)? = nil,
        onHideSelectedApp: (@MainActor () -> Bool)? = nil
    ) {
        guard monitor == nil else { return }
        self.isKillConfirmationActive = killConfirmationActive

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            Self.logKey(
                "down keyCode=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "") flagsRaw=\(flags.rawValue) inCommand=\(inCommandMode())"
            )

            // Modal: eats what it does not recognise so no shortcut can act on a
            // selection mid-hide. Cmd+Q is exempt, a prompt must not trap the user.
            if hideAppConfirmationActive() {
                let char = event.charactersIgnoringModifiers?.lowercased()
                if flags == [.command] && char == "q" {
                    return event
                }
                if event.keyCode == KeyCode.escape {
                    onCancelHideApp?()
                    return nil
                }
                if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter {
                    onConfirmHideApp?()
                    return nil
                }
                if char == "y" {
                    onConfirmHideApp?()
                    return nil
                }
                if char == "n" {
                    onCancelHideApp?()
                    return nil
                }
                return nil
            }

            // Open: the menu owns navigation. ⌘J/⌘K and ⌃J/⌃K step through it
            // (vim-style), arrows do the same, Escape closes. Anything else
            // falls through, so typing still reaches the query field.
            if inActionMenu() {
                let character = event.charactersIgnoringModifiers?.lowercased()
                if event.keyCode == KeyCode.escape {
                    onActionMenuClose()
                    return nil
                }
                if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter {
                    onActionMenuRun()
                    return nil
                }
                if event.keyCode == KeyCode.arrowDown
                    || (Self.isActionMenuChord(flags) && (event.keyCode == KeyCode.j || character == "j"))
                {
                    onActionMenuMove(1)
                    return nil
                }
                if event.keyCode == KeyCode.arrowUp
                    || (Self.isActionMenuChord(flags) && (event.keyCode == KeyCode.k || character == "k"))
                {
                    onActionMenuMove(-1)
                    return nil
                }
            }

            // ⌘K opens it, and ⌘J opens it too and starts on the first row, so
            // either half of the pair gets you in. ⌃J/⌃K do the same.
            if Self.isActionMenuChord(flags),
                event.keyCode == KeyCode.k || event.keyCode == KeyCode.j
                    || event.charactersIgnoringModifiers?.lowercased() == "k"
                    || event.charactersIgnoringModifiers?.lowercased() == "j"
            {
                onToggleActionMenu()
                return nil
            }

            if flags.contains(.command)
                && !flags.contains(.control)
                && !flags.contains(.option)
                && (event.keyCode == KeyCode.slash
                    || event.charactersIgnoringModifiers == "/"
                    || event.charactersIgnoringModifiers == "?")
            {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    onEnterCommandMode()
                }
                return nil
            }


            if (event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter) && flags == [.command] {
                onWebSearch()
                return nil
            }

            if (event.keyCode == KeyCode.f || event.charactersIgnoringModifiers?.lowercased() == "f")
                && flags == [.command]
            {
                onRevealInFinder()
                return nil
            }

            if (event.keyCode == KeyCode.e || event.charactersIgnoringModifiers?.lowercased() == "e")
                && flags == [.command]
            {
                onEditSelection()
                return nil
            }

            if (event.keyCode == KeyCode.t || event.charactersIgnoringModifiers?.lowercased() == "t")
                && flags == [.command]
            {
                onOpenTerminalForSelection()
                return nil
            }

            if (event.keyCode == KeyCode.c || event.charactersIgnoringModifiers?.lowercased() == "c")
                && flags == [.command]
            {
                if onCopySelection() {
                    return nil
                }
                return event
            }

            // ⌘. stops a running generation (the macOS-standard cancel chord).
            // The handler gates itself, so it only fires while streaming.
            if event.charactersIgnoringModifiers == "." && flags == [.command] {
                if onStopGeneration?() == true {
                    return nil
                }
                return event
            }

            // Undo the last action (its result row is showing). The handler gates
            // itself, so Cmd+Z passes through to text-field undo otherwise.
            if event.charactersIgnoringModifiers?.lowercased() == "z" && flags == [.command] {
                if onUndoAction?() == true {
                    return nil
                }
                return event
            }

            // The handler owns the gating, so the key is only consumed when it acts.
            if (event.keyCode == KeyCode.h || event.charactersIgnoringModifiers?.lowercased() == "h")
                && flags == [.command, .shift]
            {
                if onHideSelectedApp?() == true {
                    return nil
                }
                return event
            }

            if (event.keyCode == KeyCode.h || event.charactersIgnoringModifiers?.lowercased() == "h")
                && flags == [.command]
            {
                if !inCommandMode() {
                    onToggleHelp()
                }
                return nil
            }

            if (event.keyCode == KeyCode.p || event.charactersIgnoringModifiers?.lowercased() == "p")
                && flags == [.command]
            {
                if !inCommandMode() {
                    onTogglePick()
                }
                return nil
            }

            if (event.keyCode == KeyCode.p || event.charactersIgnoringModifiers?.lowercased() == "p")
                && flags == [.command, .shift]
            {
                if !inCommandMode() {
                    onClearPicked()
                }
                return nil
            }

            if (event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter) && flags == [.command, .shift] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    onSelectCommandByIndex(1)
                }
                return nil
            }

            // Shift+Enter opens every picked file/folder at once. Only when
            // there are picks; otherwise fall through so plain submit still
            // opens the selected result.
            if (event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter) && flags == [.shift] {
                if !inCommandMode() && hasPickedItems() {
                    onOpenAllPicked()
                    return nil
                }
                return event
            }

            // Cmd+D (keyCode 2) → trash the selection. Only in result mode; in
            // command mode it falls through so it keeps any text-editing meaning
            // in the command input.
            if (event.keyCode == KeyCode.d || event.charactersIgnoringModifiers?.lowercased() == "d")
                && flags == [.command]
                && !inCommandMode()
            {
                onRequestDelete?()
                return nil
            }


            if event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control)
                && !event.modifierFlags.contains(.option)
            {
                // macOS digit keyCodes are not contiguous: 1=18, 2=19, 3=20, 4=21, 5=23, 6=22, 7=26, 8=28, 9=25, 0=29.
                let cmdNumberKey: Int?
                switch event.keyCode {
                case 18: cmdNumberKey = 1
                case 19: cmdNumberKey = 2
                case 20: cmdNumberKey = 3
                case 21: cmdNumberKey = 4
                case 23: cmdNumberKey = 5
                case 22: cmdNumberKey = 6
                case 26: cmdNumberKey = 7
                case 28: cmdNumberKey = 8
                case 25: cmdNumberKey = 9
                // Everything below is 1-based and declines 0, so ⌘0 keeps
                // its "Actual Size" meaning everywhere.
                case 29: cmdNumberKey = 0
                default: cmdNumberKey = nil
                }
                if let key = cmdNumberKey {
                    if inCommandMode() {
                        if key > 0, key <= AppConstants.Launcher.commandCatalog.count {
                            Self.logger.debug("⌘+\(key, privacy: .public) -> command catalog")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                                onSelectCommandByIndex(key)
                            }
                            return nil
                        }
                        Self.logger.debug(
                            "⌘+\(key, privacy: .public) ignored (command mode maps 1-\(AppConstants.Launcher.commandCatalog.count, privacy: .public))")
                    } else {
                        // The strip badges are 1-9, so 0 addresses no icon and
                        // falls through to its "Actual Size" menu equivalent.
                        if key > 0 {
                            Self.logger.debug("⌘+\(key, privacy: .public) -> running-apps switcher")
                            if onActivateRunningApp(key) {
                                return nil
                            }
                            Self.logger.debug(
                                "⌘+\(key, privacy: .public) running-apps activation declined, falling through"
                            )
                        }
                    }
                }
            }

            // Only consume it when it actually acts, so Shift+Esc keeps its
            // command-mode "hide" meaning elsewhere.
            if event.keyCode == KeyCode.escape,
                flags.contains(.shift),
                !flags.contains(.command),
                !flags.contains(.option),
                !flags.contains(.control),
                onEscapeHome?() == true
            {
                return nil
            }

            // ⌥↑/↓ walks the AI prompt history. It has to sit ABOVE the modifier
            // passthrough below, which hands every Option combo to the system.
            // Not ⌃↑/↓: those are Mission Control and Application Windows at the
            // WindowServer level, so the app never sees them. Not ⇧↑/↓ either -
            // the composer is multiline now and needs them to select text.
            if event.keyCode == KeyCode.arrowUp || event.keyCode == KeyCode.arrowDown,
                flags.contains(.option),
                !flags.contains(.command),
                !flags.contains(.control),
                // ⌥⇧↑/↓ extends the selection by paragraph in the composer.
                // Claiming it here would replace the draft with a history entry
                // while the user is trying to select text.
                !flags.contains(.shift)
            {
                let older = event.keyCode == KeyCode.arrowUp
                if onRecallPrompt?(older) == true { return nil }
                return event
            }

            if event.modifierFlags.contains(.command)
                || event.modifierFlags.contains(.option)
                || event.modifierFlags.contains(.control)
            {
                Self.logKey("passthrough keyCode=\(event.keyCode) (modifier key combo)")
                return event
            }

            if event.keyCode == KeyCode.escape {
                if onDismissHelpIfVisible() {
                    return nil
                }

                if killConfirmationActive() {
                    onCancelKill?()
                    return nil
                }

                if deleteConfirmationActive() {
                    onCancelDelete?()
                    return nil
                }

                if actionConfirmationActive() {
                    onCancelAction?()
                    return nil
                }

                // Inside a drill-down, Escape goes back one level rather than
                // closing the launcher: the way out of a list is the way you
                // came into it.
                if onPopLevel?() == true {
                    return nil
                }

                if inCommandMode() {
                    if flags.contains(.shift) {
                        onHideLauncher()
                    } else {
                        onExitCommandMode()
                    }
                } else {
                    onHideLauncher()
                }
                return nil
            }

            if killConfirmationActive() {
                let char = event.charactersIgnoringModifiers?.lowercased()
                if char == "y" {
                    onConfirmKill?()
                    return nil
                }
                if char == "n" {
                    onCancelKill?()
                    return nil
                }
            }

            if deleteConfirmationActive() {
                // Enter confirms too - and must be swallowed so it doesn't fall
                // through to handleSubmit and *open* the file being deleted.
                if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter {
                    onConfirmDelete?()
                    return nil
                }
                let char = event.charactersIgnoringModifiers?.lowercased()
                if char == "y" {
                    onConfirmDelete?()
                    return nil
                }
                if char == "n" {
                    onCancelDelete?()
                    return nil
                }
            }

            if event.keyCode == KeyCode.tab {
                if event.modifierFlags.contains(.shift) {
                    onPrevious()
                } else {
                    onNext()
                }
                return nil
            }

            // Shift+↑/↓ belongs to the text field: it extends the selection.
            // Passed through untouched - the plain-arrow handlers below take no flags
            // into account, so without this they would swallow it.
            if event.keyCode == KeyCode.arrowUp || event.keyCode == KeyCode.arrowDown,
                flags.contains(.shift)
            {
                return event
            }

            if event.keyCode == KeyCode.arrowUp {
                if let onArrowUp {
                    onArrowUp()
                } else {
                    onPrevious()
                }
                return nil
            }

            if event.keyCode == KeyCode.arrowDown {
                if let onArrowDown {
                    onArrowDown()
                } else {
                    onNext()
                }
                return nil
            }

            return event
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
