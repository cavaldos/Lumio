import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ThemeSettingsView: View {
    /// Outcome carried with the text so a failed save cannot be styled as a
    /// success by a stale flag.
    struct SaveMessage {
        let text: String
        let succeeded: Bool
    }

    static let activeFillOpacity = 0.16
    static let inactiveFillOpacity = 0.06

    @EnvironmentObject var appUIState: AppUIState
    @EnvironmentObject var themeStore: ThemeStore
    @Binding var settings: ThemeSettings
    @State var saveMessage: SaveMessage?
    @State var fileScanDepthInput = ""
    @State var fileScanLimitInput = ""
    @State var fileScanDepthError: String?
    @State var fileScanLimitError: String?
    @State var extraScanDirectoryMessage: String?
    @State var showFreshConfigConfirm = false
    @State var freshConfigMessage: String?
    @State var localKeyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings")
                    .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize + 2), weight: .semibold))
                Spacer()

                if let saveMessage {
                    Text(saveMessage.text)
                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .semibold))
                        .foregroundStyle(saveMessage.succeeded ? themeStore.onSuccessColor() : themeStore.onDangerColor())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            saveMessage.succeeded ? themeStore.successColor() : themeStore.dangerColor(),
                            in: Capsule()
                        )
                }

                Button("Save Config") {
                    applyFileScanDepthInput()
                    applyFileScanLimitInput()
                    let ok = themeStore.saveCurrentConfigToFile()
                    saveMessage = SaveMessage(text: ok ? "Saved" : "Save failed", succeeded: ok)
                    if ok {
                        NotificationCenter.default.post(name: .lookReloadConfigRequested, object: nil)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        saveMessage = nil
                    }
                }
                .disabled(hasIndexingError)
                .opacity(hasIndexingError ? 0.5 : 1)
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))

                Button("Back to Launcher") {
                    closeSettingsPanel()
                }
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
            }

            settingsPage
                .frame(maxHeight: .infinity, alignment: .top)

        }
        .onExitCommand {
            closeSettingsPanel()
        }
        .onAppear {
            installLocalKeyMonitorIfNeeded()
        }
        .onDisappear {
            removeLocalKeyMonitor()
        }
        .alert("Create fresh config file?", isPresented: $showFreshConfigConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Create Fresh Config", role: .destructive) {
                runFreshConfigReset()
            }
        } message: {
            Text("This will replace your current config file with default values.")
        }
    }

    func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text("▶")
                .font(.system(size: CGFloat(AppConstants.ThemeUI.fontSize - 2)))
                .foregroundStyle(themeStore.secondaryTextColor())

            Text(title)
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .semibold))
                .foregroundStyle(themeStore.secondaryTextColor())

            Spacer(minLength: 0)
        }
    }

    func presetRow(title: String, options: [String], selected: Int?, onPick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: AppConstants.ThemeUI.labelWidth, alignment: .leading)
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
                .foregroundStyle(themeStore.secondaryTextColor())

            HStack(spacing: 8) {
                ForEach(options.indices, id: \.self) { index in
                    let isActive = selected == index
                    Button {
                        onPick(index)
                    } label: {
                        Text(options[index])
                            .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? themeStore.fontColor() : themeStore.secondaryTextColor())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                themeStore.liftColor(opacity: isActive ? Self.activeFillOpacity : Self.inactiveFillOpacity),
                                in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
    }

    func closeSettingsPanel() {
        appUIState.showsThemeSettings = false
        NotificationCenter.default.post(name: .lookRefocusInputRequested, object: nil)
    }

    func installLocalKeyMonitorIfNeeded() {
        guard localKeyMonitor == nil else { return }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // The settings window is reused after closing, so onDisappear may
            // never fire and this monitor stays installed. Only act while
            // settings is shown; otherwise it would swallow Cmd+Shift+, and Esc
            // for the rest of the app.
            guard appUIState.showsThemeSettings else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 53 && flags.isEmpty {
                closeSettingsPanel()
                return nil
            }

            if showFreshConfigConfirm,
               flags.isEmpty,
               event.charactersIgnoringModifiers?.lowercased() == "y" {
                showFreshConfigConfirm = false
                runFreshConfigReset()
                return nil
            }

            if flags == [.command, .shift]
                && (event.charactersIgnoringModifiers == "," || event.keyCode == 43)
            {
                closeSettingsPanel()
                return nil
            }

            return event
        }
    }

    func removeLocalKeyMonitor() {
        guard let localKeyMonitor else { return }
        NSEvent.removeMonitor(localKeyMonitor)
        self.localKeyMonitor = nil
    }
}
