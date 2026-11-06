//
//  SpotlightOpener.swift
//  lumio-app
//
//  Opens a Spotlight launcher row and runs Tab actions. Same approach as the legacy
//  launcher (LauncherView+Results): check the target still exists, record usage in the
//  core so ranking improves next time, open apps without stealing focus if the user
//  has moved elsewhere while a heavy app is launching.
//

import AppKit
import OSLog

nonisolated private let spotlightOpenLog = Logger(subsystem: "com.cavaldos.Lumio", category: "spotlight-open")

enum SpotlightOpener {
    enum Outcome {
        /// Handed off to another app: the launcher closes and does not return focus to the previous app.
        case launched
        /// Stay in the launcher and report via a toast.
        case message(String)
    }

    // MARK: - Open

    static func open(_ item: SpotlightItem) -> Outcome {
        switch item.kind {
        case .calc:
            guard let value = item.calcResult else { return .message("Couldn't calculate") }
            let text = SpotlightCalc.format(value)
            copy(text)
            return .message("Copied \(text)")
        case .web:
            openWebSearch(item.name)
            return .launched
        case .url:
            guard let target = item.target, openURL(target) else { return .message("Couldn't open link") }
            let url = target
            Task.detached(priority: .utility) { _ = EngineBridge.shared.recordURLHit(url: url) }
            return .launched
        case .app, .setting, .doc, .content, .folder:
            return openTarget(of: item)
        case .clip:
            guard let text = item.payload else { return .message("Nothing to copy") }
            copy(text)
            return .message("Copied")
        case .cmd, .prefix, .command, .clipImage, .lookup, .translation, .process, .help:
            // These modes need view state (store, model): the view handles them.
            return .message("Nothing to open")
        }
    }

    private static func openTarget(of item: SpotlightItem) -> Outcome {
        guard let target = item.target else { return .message("No target to open") }
        let isURL = isURLScheme(target)
        if !isURL, !FileManager.default.fileExists(atPath: target) {
            // Still in the index but deleted/moved: refresh so the core drops it.
            Task.detached(priority: .utility) { _ = EngineBridge.shared.requestIndexRefresh() }
            return .message("This item no longer exists — refreshing the index")
        }

        switch item.kind {
        case .app where !isURL:
            launchApp(at: target)
        case .app, .setting:
            guard openURL(target) else { return .message("Couldn't open \(item.name)") }
        default:
            openFile(target)
        }
        recordUsage(item)
        return .launched
    }

    // MARK: - Actions (⌘K)

    static func perform(_ action: SpotlightAction, on item: SpotlightItem) -> Outcome {
        guard let target = item.target else { return .message("No target") }
        switch action {
        case .open:
            return open(item)
        case .reveal:
            guard !isURLScheme(target), FileManager.default.fileExists(atPath: target) else {
                return .message("Couldn't show in Finder")
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
            return .launched
        case .copyPath:
            copy(target)
            return .message("Copied path")
        case .hideApp:
            guard let app = runningApp(at: target) else { return .message("\(item.name) isn't running") }
            app.hide()
            return .launched
        case .quitApp:
            guard let app = runningApp(at: target) else { return .message("\(item.name) isn't running") }
            app.terminate()
            return .launched
        case .measureCPU, .killProcess, .copyPID,
             .openInEditor, .openInTerminal, .moveToTrash, .emptyTrash, .excludeApp:
            // Need view state (process model, confirmation, async tool run): the view handles them.
            return .message("Not applicable")
        }
    }

    static func runningApp(at path: String) -> NSRunningApplication? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL.path == wanted
        }
    }

    // MARK: - System

    private static func launchApp(at path: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let ownPID = ProcessInfo.processInfo.processIdentifier
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { app, error in
            DispatchQueue.main.async {
                if let error {
                    spotlightOpenLog.error("openApplication failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return
                }
                guard let app else { return }
                // Heavy apps take a few seconds to launch: if the user has already switched to
                // another app, don't pull focus back.
                if let front = NSWorkspace.shared.frontmostApplication,
                   front.processIdentifier != ownPID,
                   front.processIdentifier != app.processIdentifier
                {
                    return
                }
                app.activate()
            }
        }
    }

    private static func openFile(_ path: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(URL(fileURLWithPath: path), configuration: config) { _, error in
            if let error {
                spotlightOpenLog.error("open failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The old `open(URL)` API hands custom schemes (x-apple.systempreferences:,
    /// https:) to LaunchServices; the configuration variant wrongly routes them to Finder.
    @discardableResult
    private static func openURL(_ target: String) -> Bool {
        guard let url = URL(string: target) else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func openWebSearch(_ text: String) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func isURLScheme(_ target: String) -> Bool {
        target.contains(":") && !target.hasPrefix("/")
    }

    /// Record the open in the core (opens the DB, so it runs in the background without blocking launcher close).
    private static func recordUsage(_ item: SpotlightItem) {
        guard let candidateID = item.candidateID else { return }
        let action = switch item.kind {
        case .doc, .content: "open_file"
        case .folder: "open_folder"
        default: "open_app"
        }
        Task.detached(priority: .utility) {
            if let error = EngineBridge.shared.recordUsage(candidateID: candidateID, action: action) {
                spotlightOpenLog.error("record usage failed: \(error.code, privacy: .public)")
            }
        }
    }
}
