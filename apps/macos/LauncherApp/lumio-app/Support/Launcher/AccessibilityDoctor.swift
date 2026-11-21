//
//  AccessibilityDoctor.swift
//  lumio-app
//
//  The dialog that says where the Accessibility permission stands (working, off or stale)
//  and offers the fix that fits.
//
//  When it appears:
//    - on its own, at most once per launch, ONLY when the permission has gone stale
//      (never just because it is off: that may be your choice);
//    - whenever you ask: Settings ▸ General ▸ Permissions ▸ Check, or ⏎ on the row the
//      `windows` tag shows while window search is unavailable;
//    - once more after a fix, to say whether it took.
//

import AppKit

@MainActor
final class AccessibilityDoctor {
    static let shared = AccessibilityDoctor()

    private static let mutedKey = "AccessibilityAccess.staleWarningMuted"
    private var warnedThisLaunch = false
    private var showing = false
    private var watch: Timer?
    private var watchDeadline = Date.distantPast

    /// The last full check, for rows that want to word themselves without checking again.
    private(set) var lastState: AccessibilityAccess.State?

    /// Called by whoever changes the state from outside the dialog (Settings rows listen).
    static let changed = Notification.Name("AccessibilityDoctor.changed")

    // MARK: - Asking

    /// Checks off the main thread and hands the answer back on it.
    func check(_ done: @escaping @MainActor (AccessibilityAccess.State) -> Void) {
        Task { @MainActor in
            let state = await Task.detached(priority: .userInitiated) { AccessibilityAccess.check() }.value
            lastState = state
            done(state)
        }
    }

    /// Always answers with a dialog, whatever the state.
    func showStatus() {
        check { [self] state in present(state, automatic: false) }
    }

    /// Speaks up only for a stale permission, once per launch, unless muted.
    func warnIfStale() {
        guard !warnedThisLaunch, !UserDefaults.standard.bool(forKey: Self.mutedKey) else { return }
        check { [self] state in
            guard case .stale = state, !warnedThisLaunch else { return }
            warnedThisLaunch = true
            present(state, automatic: true)
        }
    }

    /// The cheap version for every time the launcher opens: only looks closer when the
    /// permission worked before and macOS now says no.
    func noticeIfLost() {
        guard !warnedThisLaunch, AccessibilityAccess.workedBefore, !AccessibilityAccess.isTrusted else { return }
        warnIfStale()
    }

    // MARK: - The dialog

    private func present(_ state: AccessibilityAccess.State, automatic: Bool, afterFix: Bool = false) {
        guard !showing else { return }
        showing = true
        defer { showing = false }

        let alert = NSAlert()
        var actions: [() -> Void] = []
        func button(_ title: String, _ action: @escaping () -> Void = {}) {
            alert.addButton(withTitle: title)
            actions.append(action)
        }

        switch state {
        case .working:
            alert.alertStyle = .informational
            alert.messageText = afterFix ? "Accessibility is working again" : "Accessibility is working"
            alert.informativeText = "Lumio can read window titles and the text you have selected. "
                + "The permission is on and macOS is honouring it, so nothing is stale."
            button("OK")

        case .off(let listed):
            alert.alertStyle = .informational
            alert.messageText = "Accessibility is off for Lumio"
            alert.informativeText = (listed
                ? "Lumio is in the list under System Settings ▸ Privacy & Security ▸ Accessibility, but its switch is off. "
                : "Lumio is not allowed under System Settings ▸ Privacy & Security ▸ Accessibility. ")
                + "This is not a stale permission: it is simply off.\n\n"
                + "Window search and looking up the selected text stay unavailable until you turn the switch on. "
                + "Everything else works without it."
            button("Open Accessibility Settings") { [self] in
                // Puts Lumio in the list (switch off) so there is something to turn on.
                if !listed { AccessibilityAccess.askMacOSToListLumio() }
                openSettings()
                startWatching()
            }
            button("Not Now")

        case .stale(.allowedButRefused):
            alert.alertStyle = .warning
            alert.messageText = "Accessibility is on, but macOS is refusing Lumio"
            alert.informativeText = "The permission is allowed, yet the requests themselves are turned down. "
                + "That happens when the permission changed while Lumio was running. Reopening Lumio fixes it."
            button("Reopen Lumio") { Self.reopen() }
            button("Not Now")

        case .stale(let kind):
            alert.alertStyle = .warning
            alert.messageText = "Lumio's Accessibility permission has gone stale"
            let what = kind == .switchOnButIgnored
                ? "The switch for Lumio is ON in System Settings ▸ Privacy & Security ▸ Accessibility, but macOS is ignoring it. "
                : "Accessibility worked for Lumio before and has stopped. Either its switch was turned off, or it is "
                + "still on and macOS is ignoring it (Lumio cannot read the list to tell which). "
            alert.informativeText = what
                + "This happens when Lumio is replaced by a newer build: the entry belongs to the old copy.\n\n"
                + "Turning the switch off and on does not help. Reset removes Lumio's entry from that list "
                + "(nothing else is touched); macOS then lists Lumio again and you turn the switch back on."
            button("Reset and Allow Again") { [self] in resetAndAllowAgain() }
            button("Open Accessibility Settings") { [self] in
                openSettings()
                startWatching()
            }
            button("Not Now")
            if automatic {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Don't warn me about this again"
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: Self.mutedKey)
        }
        let index = answer.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if actions.indices.contains(index) { actions[index]() }
    }

    // MARK: - Fixes

    private func openSettings() {
        if let url = URL(string: AccessibilityAccess.settingsURL) { NSWorkspace.shared.open(url) }
    }

    private func resetAndAllowAgain() {
        guard AccessibilityAccess.removeEntry() else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "macOS would not remove the entry"
            alert.informativeText = "Remove it by hand: in the Accessibility list, select Lumio and press the − button. "
                + "Then add Lumio again with + and turn its switch on."
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                openSettings()
                startWatching()
            }
            return
        }
        lastState = .off(listed: false)
        NotificationCenter.default.post(name: Self.changed, object: nil)
        AccessibilityAccess.askMacOSToListLumio()
        openSettings()
        startWatching()
    }

    /// After a fix was started: look every second for the switch being turned on, then say
    /// whether it took. Gives up quietly after three minutes.
    private func startWatching() {
        watch?.invalidate()
        watchDeadline = Date().addingTimeInterval(180)
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AccessibilityDoctor.shared.watchTick() }
        }
    }

    private func watchTick() {
        if Date() > watchDeadline {
            watch?.invalidate()
            watch = nil
            return
        }
        guard AccessibilityAccess.isTrusted else { return }
        watch?.invalidate()
        watch = nil
        check { [self] state in
            NotificationCenter.default.post(name: Self.changed, object: nil)
            if state == .working { OpenWindows.shared.refresh() }
            present(state, automatic: false, afterFix: true)
        }
    }

    /// Quits and starts Lumio again a moment later.
    private static func reopen() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1.2; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}
