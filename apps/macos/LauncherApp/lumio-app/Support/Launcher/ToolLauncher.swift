import AppKit
import Foundation

/// ⌘E / ⌘T: open a file or folder with the editor / terminal the user named in their
/// config. Which tool and how it's invoked is decided in core (`lumio-tools`).
@MainActor
enum ToolLauncher {
    enum Outcome {
        /// Handed off to the tool: the launcher closes without returning focus.
        case launched
        case message(String)
    }

    private typealias Tools = AppConstants.Launcher.Tools

    static func run(
        _ action: String, candidateID: String, title: String, path: String, isDirectory: Bool
    ) async -> Outcome {
        let row = ToolActionRow(candidateID: candidateID, title: title, path: path)
        let outcome = await Task.detached(priority: .userInitiated) {
            EngineBridge.shared.performToolAction(action, row: row, isDirectory: isDirectory)
        }.value
        guard let outcome else { return .message("Couldn't run \(action)") }

        switch outcome.kind {
        case .performed:
            activateTool(named: outcome.tool)
            return .launched
        case .application:
            return launchApplication(tool: outcome.tool, path: outcome.path ?? path)
        case .systemDefault:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: outcome.path ?? path)])
            return .launched
        case .unavailable, .failed:
            return .message(outcome.reason ?? "Couldn't run \(action)")
        case .shell:
            // Only the resolve-only entry point returns this.
            return .message("Couldn't run \(action)")
        }
    }

    private static func launchApplication(tool: String?, path: String) -> Outcome {
        guard let tool else { return .message("No tool configured") }
        guard let bundle = AppBundleLocator.bundlePath(forAppNamed: tool) else {
            return .message("\(Tools.launchFailedBanner) \(tool)")
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: URL(fileURLWithPath: bundle),
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
        return .launched
    }

    /// Bring the terminal forward once its new window exists. A terminal that is already running
    /// (e.g. `wezterm start`) never asks to come forward, and Lumio still holds activation, so
    /// Lumio passes it on.
    private static func activateTool(named tool: String?) {
        guard let tool, let bundle = AppBundleLocator.bundlePath(forAppNamed: tool) else { return }
        let target = URL(fileURLWithPath: bundle).resolvingSymlinksInPath()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Tools.activationSettleNanoseconds)
            for _ in 0..<Tools.activationPollAttempts {
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleURL?.resolvingSymlinksInPath() == target
                }) {
                    // The user may have moved on while a cold terminal started.
                    if let front = NSWorkspace.shared.frontmostApplication,
                       front.processIdentifier != ownPID,
                       front.processIdentifier != app.processIdentifier
                    {
                        return
                    }
                    app.activate()
                    return
                }
                try? await Task.sleep(nanoseconds: Tools.activationPollNanoseconds)
            }
        }
    }
}
