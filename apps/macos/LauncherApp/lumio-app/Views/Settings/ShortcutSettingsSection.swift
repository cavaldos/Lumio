import AppKit
import SwiftUI

/// Settings ▸ Shortcuts: a global shortcut for the launcher, Settings and each launcher tab.
/// Click a shortcut, press the new keys; ⌫ clears it, Esc cancels. Takes effect right away.
struct ShortcutSettingsSection: View {
    /// Read by the Settings window's own key monitor so Esc cancels recording instead of
    /// closing the window.
    static var isRecording = false

    @EnvironmentObject var themeStore: ThemeStore
    @Binding var settings: ThemeSettings
    @State private var recording: HotKeyAction?
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(HotKeyAction.allCases) { action in
                row(action)
            }

            HStack(spacing: 8) {
                if let message {
                    Text(message)
                        .foregroundStyle(themeStore.dangerColor())
                } else {
                    Text("Click a shortcut, then press the keys. ⌫ clears it, Esc cancels. Save Config to keep it.")
                        .foregroundStyle(themeStore.mutedTextColor())
                }
                if settings.hotkeys != HotKeyAction.defaultValues {
                    Button("Reset") {
                        stopRecording()
                        settings.hotkeys = HotKeyAction.defaultValues
                    }
                }
            }
            .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
        }
        .onDisappear { stopRecording() }
        // Clicking away (another window or app) ends recording, so the shortcuts aren't left paused.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
        }
    }

    private func row(_ action: HotKeyAction) -> some View {
        let combo = settings.hotKey(for: action)
        let isRecording = recording == action
        return HStack(spacing: 10) {
            Text(action.title)
                .frame(width: AppConstants.ThemeUI.labelWidth, alignment: .leading)
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
                .foregroundStyle(themeStore.secondaryTextColor())

            Button {
                isRecording ? stopRecording() : startRecording(action)
            } label: {
                Text(isRecording ? "Press keys…" : combo?.display ?? "Record Shortcut")
                    .font(themeStore.uiFont(
                        size: CGFloat(AppConstants.ThemeUI.fontSize - 1),
                        weight: combo != nil && !isRecording ? .semibold : .regular
                    ))
                    .foregroundStyle(combo != nil || isRecording ? themeStore.fontColor() : themeStore.secondaryTextColor())
                    .frame(minWidth: 120)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        themeStore.liftColor(opacity: isRecording ? 0.24 : ThemeSettingsView.activeFillOpacity),
                        in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
                    )
                    .overlay {
                        if isRecording {
                            RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if combo != nil, !isRecording {
                Button {
                    set(action, to: nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(themeStore.mutedTextColor())
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }

            Text(action.detail)
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                .foregroundStyle(themeStore.mutedTextColor())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Recording

    private func startRecording(_ action: HotKeyAction) {
        stopRecording()
        recording = action
        message = nil
        Self.isRecording = true
        // Pause the current shortcuts so pressing one records it instead of firing it.
        NotificationCenter.default.post(name: .lookHotKeyRecordingChanged, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    private func stopRecording() {
        guard recording != nil || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        Self.isRecording = false
        NotificationCenter.default.post(name: .lookHotKeyRecordingChanged, object: false)
    }

    /// A key pressed while recording. `true` = consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard let action = recording else { return false }
        let flags = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
        if flags.isEmpty, event.keyCode == AppConstants.Launcher.KeyCode.escape {
            stopRecording()
            return true
        }
        if flags.isEmpty, event.keyCode == 51 {  // ⌫
            set(action, to: nil)
            stopRecording()
            return true
        }
        guard let combo = KeyCombo(event: event) else { return true }
        guard combo.isUsableGlobally else {
            message = "Add ⌘, ⌥ or ⌃ — \(combo.display) alone would block typing."
            return true
        }
        if let other = HotKeyAction.allCases.first(where: { $0 != action && settings.hotKey(for: $0) == combo }) {
            message = "\(combo.display) is already used by \(other.title)."
            return true
        }
        set(action, to: combo)
        stopRecording()
        return true
    }

    private func set(_ action: HotKeyAction, to combo: KeyCombo?) {
        message = nil
        settings.hotkeys[action.rawValue] = combo?.configValue ?? ""
    }
}
