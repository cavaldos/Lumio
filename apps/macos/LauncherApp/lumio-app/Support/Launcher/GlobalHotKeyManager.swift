import AppKit
import Carbon
import OSLog

nonisolated private let hotkeyLog = Logger(subsystem: "com.cavaldos.Lumio", category: "hotkey")

@MainActor
final class GlobalHotKeyManager {
    /// One global shortcut: the Carbon id it registers under, its keys, and
    /// the notification it posts when pressed.
    nonisolated private struct Binding: Sendable {
        let id: UInt32
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let modifierFlags: NSEvent.ModifierFlags
        let notification: Notification.Name
        let label: String
    }

    /// Option+Space toggles the launcher; Cmd+Shift+Space opens settings.
    private static let bindings: [Binding] = [
        Binding(
            id: 1, keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey),
            modifierFlags: [.option], notification: .lookToggleWindowRequested,
            label: "Option+Space"),
        Binding(
            id: 2, keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | shiftKey),
            modifierFlags: [.command, .shift], notification: .lookToggleSettingsRequested,
            label: "Cmd+Shift+Space"),
    ]

    // nonisolated(unsafe) so the nonisolated deinit can release these
    // (they're Carbon/AppKit handles - not actually Sendable, but they're
    // only mutated from MainActor anyway).
    nonisolated(unsafe) private var hotKeyRefs: [EventHotKeyRef] = []
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    // Carbon's RegisterEventHotKey only fires when the registering app is
    // NOT the currently-active app. When Lumio is in the foreground (e.g.
    // user has the launcher open and focused), the shortcuts go through
    // the normal local event chain instead. Install a parallel local
    // NSEvent monitor so they work regardless of focus state.
    nonisolated(unsafe) private var localMonitor: Any?

    // Defense-in-depth for one specific, rare failure: another app already
    // owns one of the shortcuts when Lumio launches, so RegisterEventHotKey returns -9878
    // ("hotkey already in use") and that shortcut silently never works.
    // Retry with backoff so a transient login-time conflict resolves on its own.
    //
    // NOTE: this is NOT what fixed "the launcher is invisible after a macOS
    // restart." That bug was the WindowGroup window never being created at a
    // background login launch (so LauncherView and its hotkey observer never
    // mounted); registration actually succeeds (status=0) in that case. The
    // real fix lives in AppDelegate (`handleToggleHotKey` materializes the
    // launcher window when the hotkey fires and no window exists yet).
    // This retry only matters if registration genuinely fails, which is uncommon.
    private var retryAttempts = 0
    private static let maxRetryAttempts = 5
    private var retryWorkItem: DispatchWorkItem?

    // deinit is nonisolated; unregister is MainActor. Inline the cleanup
    // here using nonisolated-safe API only.
    deinit {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    func registerToggleHotKey() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        unregister()

        var allRegistered = true
        for binding in Self.bindings {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.carbonModifiers,
                EventHotKeyID(signature: fourCharCode("LUMIO"), id: binding.id),
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            hotkeyLog.notice(
                "RegisterEventHotKey \(binding.label, privacy: .public) status=\(status) (noErr=0; -9878=hotkey already in use)"
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                allRegistered = false
            }
        }

        if !hotKeyRefs.isEmpty {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetEventDispatcherTarget(),
                { _, event, _ in
                    var hotKeyId = EventHotKeyID()
                    let status = GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyId
                    )
                    guard status == noErr, hotKeyId.signature == fourCharCode("LUMIO") else { return noErr }

                    let id = hotKeyId.id
                    DispatchQueue.main.async {
                        guard let binding = GlobalHotKeyManager.bindings.first(where: { $0.id == id }) else { return }
                        hotkeyLog.notice("CARBON hotkey \(binding.label, privacy: .public) fired (app active=\(NSApp.isActive))")
                        NotificationCenter.default.post(name: binding.notification, object: nil)
                    }
                    return noErr
                },
                1,
                &eventType,
                nil,
                &eventHandler
            )
        }

        if allRegistered {
            retryAttempts = 0
        } else {
            scheduleRetry()
        }

        // Local monitor: foreground-focused complement to the global
        // Carbon hotkeys. Posts the same notifications so the rest of the
        // app doesn't need to know which path delivered the event.
        // Local monitors are always called on the main thread.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = UInt32(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let binding = Self.bindings.first(where: {
                    keyCode == $0.keyCode && flags == $0.modifierFlags
                }) else {
                    return false
                }
                hotkeyLog.notice("LOCAL monitor \(binding.label, privacy: .public) fired (app active=\(NSApp.isActive))")
                NotificationCenter.default.post(name: binding.notification, object: nil)
                return true
            }
            return handled ? nil : event   // consume - don't let any field eat the space
        }
    }

    private func scheduleRetry() {
        guard retryAttempts < Self.maxRetryAttempts else {
            hotkeyLog.error("RegisterEventHotKey still failing after \(Self.maxRetryAttempts) attempts; giving up on global hotkey")
            return
        }
        retryAttempts += 1
        // Ramp the delay so we react quickly to a brief login-time conflict
        // but back off if it persists: 0.5s, 1.0s, ... capped at 3s.
        let delay = min(3.0, 0.5 * Double(retryAttempts))
        hotkeyLog.notice("scheduling hotkey re-registration attempt \(self.retryAttempts) in \(delay)s")
        let work = DispatchWorkItem { [weak self] in
            self?.registerToggleHotKey()
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func unregister() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}

private func fourCharCode(_ text: String) -> OSType {
    text.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}
