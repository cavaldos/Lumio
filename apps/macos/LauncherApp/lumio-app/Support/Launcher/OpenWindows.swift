//
//  OpenWindows.swift
//  lumio-app
//
//  The open windows of every running app as search results, like Fluent Search's Windows
//  search app: ⏎ switches to the window, even a minimized one.
//
//  Window titles come from the Accessibility API, so this only works once Lumio is allowed
//  under System Settings ▸ Privacy & Security ▸ Accessibility (the same permission the
//  Dictionary shortcut uses to read the selected text). Without it there are simply no
//  window rows; the `windows` tag says what to turn on.
//
//  A snapshot is taken in the background each time the launcher opens. Every app gets a
//  short time limit, so one frozen app cannot hold the others up.
//

import AppKit
import ApplicationServices

nonisolated struct OpenWindow: Equatable, Sendable {
    /// "window|<pid>|<index>": also the row id.
    let id: String
    let title: String
    let appName: String
    let appPath: String?
    let pid: pid_t
    let minimized: Bool
}

nonisolated final class OpenWindows: @unchecked Sendable {
    static let shared = OpenWindows()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.cavaldos.Lumio.windows", qos: .userInitiated)
    private var windows: [OpenWindow] = []
    private var elements: [String: AXUIElement] = [:]
    private var refreshing = false

    /// Whether macOS lets Lumio read window titles. Never prompts.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The pane where the permission is granted.
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    var snapshot: [OpenWindow] { lock.withLock { windows } }

    /// Reads the windows of every regular app again, off the main thread.
    @MainActor
    func refresh(completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard Self.isTrusted else { return }
        lock.lock()
        if refreshing {
            lock.unlock()
            return
        }
        refreshing = true
        lock.unlock()

        let own = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own }
            .map { (pid: $0.processIdentifier, name: $0.localizedName ?? "App", path: $0.bundleURL?.path) }
        queue.async { [self] in
            var found: [OpenWindow] = []
            var refs: [String: AXUIElement] = [:]
            for app in apps {
                let element = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(element, 0.2)
                guard let list = Self.value(element, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                for (index, window) in list.enumerated() {
                    guard let title = Self.value(window, kAXTitleAttribute) as? String else { continue }
                    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { continue }
                    // Real windows only: no tooltips, popovers or floating palettes without a title bar.
                    if let subrole = Self.value(window, kAXSubroleAttribute) as? String,
                       subrole != (kAXStandardWindowSubrole as String), subrole != (kAXDialogSubrole as String)
                    {
                        continue
                    }
                    let id = "window|\(app.pid)|\(index)"
                    found.append(OpenWindow(
                        id: id, title: clean, appName: app.name, appPath: app.path, pid: app.pid,
                        minimized: (Self.value(window, kAXMinimizedAttribute) as? Bool) ?? false
                    ))
                    refs[id] = window
                }
            }
            lock.lock()
            let changed = found != windows
            windows = found
            elements = refs
            refreshing = false
            lock.unlock()
            if changed, let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    /// Windows whose title or app name contains every word of `text`; title matches first.
    /// Empty text = every window. `skipping`: app paths to leave out (browsers, whose tabs
    /// are already listed one by one).
    func search(_ text: String, limit: Int, skipping: (String) -> Bool = { _ in false }) -> [OpenWindow] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        let pool = snapshot.filter { window in window.appPath.map { !skipping($0) } ?? true }
        guard !words.isEmpty else { return Array(pool.prefix(limit)) }
        let needle = words.joined(separator: " ")
        return pool
            .compactMap { window -> (OpenWindow, Int)? in
                let title = window.title.lowercased()
                let haystack = title + " " + window.appName.lowercased()
                guard words.allSatisfy(haystack.contains) else { return nil }
                return (window, title.hasPrefix(needle) ? 2 : title.contains(needle) ? 1 : 0)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Brings the window to the front (un-minimizing it first). False when it is gone.
    func activate(id: String) -> Bool {
        guard let (window, element) = entry(id) else { return false }
        if window.minimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        return NSRunningApplication(processIdentifier: window.pid)?.activate() ?? false
    }

    /// Presses the window's close button. False when the window has none or is gone.
    func close(id: String) -> Bool {
        guard let (_, element) = entry(id),
              let button = Self.value(element, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID()
        else { return false }
        let pressed = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
        if pressed {
            lock.withLock {
                windows.removeAll { $0.id == id }
                elements[id] = nil
            }
        }
        return pressed
    }

    private func entry(_ id: String) -> (OpenWindow, AXUIElement)? {
        lock.withLock {
            guard let window = windows.first(where: { $0.id == id }), let element = elements[id] else { return nil }
            return (window, element)
        }
    }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
