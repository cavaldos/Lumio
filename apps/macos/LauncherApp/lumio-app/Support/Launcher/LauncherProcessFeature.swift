import AppKit
import UniformTypeIdentifiers

/// Query detection, row construction, and icon resolution for the `ps"` process
/// finder. `AppConstants.Launcher.Process`
/// holds the constants, this owns the logic.
enum LauncherProcessFeature {

    /// The text typed after `ps"` (empty when just the prefix is present), or
    /// nil when `query` isn't a process query.
    static func searchTerm(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = AppConstants.Launcher.QueryPrefix.process
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// App-backed process → its app icon; otherwise a generic process glyph.
    /// Single source for the row, preview, and `/kill` list.
    static func icon(forPID pid: Int32) -> NSImage {
        if let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            return icon
        }
        return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
    }
}
