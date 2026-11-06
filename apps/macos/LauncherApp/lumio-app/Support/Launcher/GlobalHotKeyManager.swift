import AppKit
import Carbon
import OSLog

nonisolated private let hotkeyLog = Logger(subsystem: "com.cavaldos.Lumio", category: "hotkey")

@MainActor
final class GlobalHotKeyManager {
    /// One global shortcut: the Carbon id it registers under, its keys, and what it does.
    nonisolated private struct Binding: Sendable {
        let id: UInt32
        let combo: KeyCombo
        let action: HotKeyAction

        var label: String { "\(action.rawValue)=\(combo.configValue)" }

        /// Toggle the launcher / settings, or open the launcher on a tab.
        @MainActor func post() {
            switch action {
            case .launcher:
                NotificationCenter.default.post(name: .lookToggleWindowRequested, object: nil)
            case .settings:
                NotificationCenter.default.post(name: .lookToggleSettingsRequested, object: nil)
            default:
                NotificationCenter.default.post(name: .lookOpenTabRequested, object: action.rawValue)
            }
        }
    }

    /// The shortcuts set in Settings (Option+Space and Cmd+Shift+Space by default).
    private static var bindings: [Binding] = []

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

    /// Registers the shortcuts in the current settings, replacing the old ones.
    func registerFromSettings() {
        let settings = ThemeStore.shared.settings
        var seen = Set<KeyCombo>()
        Self.bindings = HotKeyAction.allCases.enumerated().compactMap { index, action in
            // One combo can only do one thing; Settings already refuses duplicates.
            guard let combo = settings.hotKey(for: action), combo.isUsableGlobally,
                  seen.insert(combo).inserted
            else { return nil }
            return Binding(id: UInt32(index + 1), combo: combo, action: action)
        }
        retryAttempts = 0
        register()
    }

    private func register() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        unregister()

        var allRegistered = true
        for binding in Self.bindings {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.combo.keyCode,
                binding.combo.carbonModifiers,
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
                        MainActor.assumeIsolated {
                            guard let binding = GlobalHotKeyManager.bindings.first(where: { $0.id == id }) else { return }
                            hotkeyLog.notice("CARBON hotkey \(binding.label, privacy: .public) fired (app active=\(NSApp.isActive))")
                            binding.post()
                        }
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
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let binding = Self.bindings.first(where: { $0.combo.matches(keyCode: keyCode, flags: flags) }) else {
                    return false
                }
                hotkeyLog.notice("LOCAL monitor \(binding.label, privacy: .public) fired (app active=\(NSApp.isActive))")
                binding.post()
                return true
            }
            return handled ? nil : event   // consume - don't let any field eat the space
        }
    }

    /// While Settings records a shortcut, the current ones must not fire (or swallow the keys).
    func setPaused(_ paused: Bool) {
        if paused {
            retryWorkItem?.cancel()
            retryWorkItem = nil
            unregister()
        } else {
            register()
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
            self?.register()
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
