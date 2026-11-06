import AppKit
import ApplicationServices

/// Reads the text selected in another app through the Accessibility API, so Option+Space
/// can open the launcher straight on a lookup of it.
///
/// Doesn't fall back to sending ⌘C: that would overwrite the clipboard, and some apps copy
/// something even with nothing selected (VS Code copies the line, Finder the file name).
enum SelectedTextReader {
    /// Longer selections are probably not meant for the dictionary.
    static let maxLength = 200

    /// nil when nothing is selected, the app doesn't expose its selection, or Lumio isn't
    /// allowed to use Accessibility (asked once).
    static func selection(in app: NSRunningApplication) -> String? {
        guard isTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not hold up the launcher.
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        // Chromium / Electron apps only build their accessibility tree once asked for it.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let focused = attribute(appElement, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID(),
              let text = attribute(focused as! AXUIElement, kAXSelectedTextAttribute) as? String
        else { return nil }

        // One line: a selection can span line breaks.
        let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty, cleaned.count <= maxLength else { return nil }
        return cleaned
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static let promptedKey = "SelectedTextReader.askedForAccessibility"

    /// Shows the system prompt the first time only; after that the user can turn it on in
    /// System Settings › Privacy & Security › Accessibility.
    private static func isTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        guard !UserDefaults.standard.bool(forKey: promptedKey) else { return false }
        UserDefaults.standard.set(true, forKey: promptedKey)
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
