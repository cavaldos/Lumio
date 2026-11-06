import AppKit
import CoreServices

/// Move to Trash / Empty Trash for the launcher. Which paths are safe to trash
/// lives in `DeleteTargetLogic` (pure, unit-tested).
enum TrashService {
    /// Moves one file or folder to the Trash. Returns an error message, or nil on success.
    @MainActor
    static func moveToTrash(_ path: String) async -> String? {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
    }

    /// Whether Lumio already may automate Finder, checked WITHOUT prompting.
    @MainActor
    static func isAutomationAllowed() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let desc = target.aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) == noErr
    }

    /// Number of items in the Trash, via Finder. nil when Finder automation is unavailable.
    /// `~/.Trash` is TCC-protected, so Finder (which has the rights) is asked instead.
    @MainActor
    static func itemCount(promptIfNeeded: Bool = true) -> Int? {
        if !promptIfNeeded && !isAutomationAllowed() { return nil }
        let (result, error) = runFinder("return count of (items of the trash)")
        if error != nil { return nil }
        return result.flatMap { Int(exactly: $0.int32Value) }
    }

    /// Empties the Trash via Finder, off the main thread. Returns an error message, or nil on success.
    /// Suppresses Finder's own "are you sure" (the launcher asks first) and restores the preference after.
    static func emptyTrash() async -> String? {
        let body = """
        set prevWarn to warns before emptying of the trash
        set warns before emptying of the trash to false
        set emptyErr to missing value
        try
            empty the trash
        on error errMsg
            set emptyErr to errMsg
        end try
        try
            set warns before emptying of the trash to prevWarn
        end try
        if emptyErr is not missing value then error emptyErr
        """
        return await Task.detached(priority: .userInitiated) { runFinder(body).1 }.value
    }

    nonisolated private static func runFinder(_ body: String) -> (NSAppleEventDescriptor?, String?) {
        let source = "tell application \"Finder\"\n\(body)\nend tell"
        guard let script = NSAppleScript(source: source) else {
            return (nil, "Could not build Finder script")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743 = Automation permission not granted (or denied).
            if code == -1743 {
                return (nil, "Allow Lumio to control Finder in System Settings ▸ Privacy ▸ Automation")
            }
            let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Finder automation failed"
            return (nil, msg)
        }
        return (result, nil)
    }
}
