//
//  SystemCommands.swift
//  lumio-app
//
//  Sleep, Lock Screen, Restart, Shut Down, Log Out, Screen Saver and Empty Trash as results
//  (Fluent Search's system commands), plus "run this in Terminal" for text starting with `>`.
//
//  Restart, Shut Down and Log Out ask macOS to show ITS OWN confirmation dialog (the one the
//  Apple menu shows), so nothing is lost on a slip and open documents can still be saved.
//  Sleep and Lock act at once: neither loses anything.
//

import AppKit
import Carbon

nonisolated struct SystemCommand: Sendable {
    let id: String
    let name: String
    /// What can be typed to find it, lowercased.
    let aliases: [String]
    let symbol: String
    let colors: String
    let detail: String
}

nonisolated enum SystemCommands {
    static let idPrefix = "system|"
    static let runPrefix = "run|"
    static let emptyTrash = "emptytrash"

    static let all: [SystemCommand] = [
        SystemCommand(id: "lock", name: "Lock Screen", aliases: ["lock", "lock screen"],
                      symbol: "lock.fill", colors: "#a7aeb8,#5e6670", detail: "Lock this Mac now"),
        SystemCommand(id: "sleep", name: "Sleep", aliases: ["sleep"],
                      symbol: "moon.fill", colors: "#9aa8ff,#4a4fd6", detail: "Put this Mac to sleep now"),
        SystemCommand(id: "screensaver", name: "Start Screen Saver", aliases: ["screensaver", "screen saver", "start screen saver"],
                      symbol: "sparkles.tv.fill", colors: "#7fe0c3,#1f9d8d", detail: "Start the screen saver"),
        SystemCommand(id: "restart", name: "Restart…", aliases: ["restart", "reboot"],
                      symbol: "arrow.clockwise", colors: "#ffb36e,#f06a2e", detail: "macOS asks before restarting"),
        SystemCommand(id: "shutdown", name: "Shut Down…", aliases: ["shutdown", "shut down", "power off", "turn off"],
                      symbol: "power", colors: "#ff8a80,#d6453a", detail: "macOS asks before shutting down"),
        SystemCommand(id: "logout", name: "Log Out…", aliases: ["logout", "log out", "sign out"],
                      symbol: "rectangle.portrait.and.arrow.right", colors: "#ffb36e,#f06a2e",
                      detail: "macOS asks before logging out"),
        SystemCommand(id: emptyTrash, name: "Empty Trash", aliases: ["empty trash", "emptytrash"],
                      symbol: "trash.slash", colors: "#ff8a80,#d6453a", detail: "⏎, then ⏎ again to empty the Trash"),
    ]

    /// Commands the typed text is heading for: three letters or more, the start of a name.
    static func matching(_ term: String) -> [SystemCommand] {
        let typed = term.trimmingCharacters(in: .whitespaces).lowercased()
        guard typed.count >= 3 else { return [] }
        return all.filter { command in command.aliases.contains { $0.hasPrefix(typed) } }
    }

    /// Whether the text is exactly a command's name ("lock", "sleep"): it then leads the list.
    static func isExact(_ term: String, _ command: SystemCommand) -> Bool {
        command.aliases.contains(term.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Runs a command. Returns a message when it could not be done, nil when it was.
    static func run(_ id: String) -> String? {
        switch id {
        case "sleep":
            return launch("/usr/bin/pmset", ["sleepnow"]) ? nil : "Couldn't put the Mac to sleep"
        case "lock":
            if lockScreen() { return nil }
            // The screen turns off; it locks if a password is required after sleep.
            return launch("/usr/bin/pmset", ["displaysleepnow"]) ? nil : "Couldn't lock the screen"
        case "screensaver":
            let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
            return NSWorkspace.shared.open(engine) ? nil : "Couldn't start the screen saver"
        case "restart": return askLoginWindow(kAEShowRestartDialog)
        case "shutdown": return askLoginWindow(kAEShowShutdownDialog)
        case "logout": return askLoginWindow(kAELogOut)
        default:
            return "Unknown command"
        }
    }

    /// `> npm run dev` + ⏎: the command runs in a new Terminal window, in your home folder,
    /// and the window stays open on a shell afterwards. Nothing runs while you type.
    static func runInTerminal(_ command: String) -> String? {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Type a command after >" }
        let script = "#!/bin/zsh\ncd ~\n\(text)\nexec \"${SHELL:-/bin/zsh}\" -l\n"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumio-run-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return "Couldn't prepare the command: \(error.localizedDescription)"
        }
        return NSWorkspace.shared.open(file) ? nil : "Couldn't open Terminal"
    }

    // MARK: - How

    private static func launch(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// The same call the Apple menu's "Lock Screen" makes. False when this macOS lacks it.
    private static func lockScreen() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            return false
        }
        typealias Lock = @convention(c) () -> Int32
        return unsafeBitCast(symbol, to: Lock.self)() == 0
    }

    /// Asks the login window for its restart / shut down / log out dialog.
    private static func askLoginWindow(_ eventID: OSType) -> String? {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: eventID, targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 2)
            return nil
        } catch {
            return "macOS refused: \(error.localizedDescription)"
        }
    }
}
