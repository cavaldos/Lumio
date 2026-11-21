import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The pages of the Settings window, listed in its sidebar (like Fluent Search's settings).
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, search, appearance, indexing, shortcuts, tabs, translation, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .search: "Search"
        case .appearance: "Appearance"
        case .indexing: "Indexing"
        case .shortcuts: "Shortcuts"
        case .tabs: "Tabs"
        case .translation: "Translation"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .search: "magnifyingglass"
        case .appearance: "paintbrush.fill"
        case .indexing: "square.stack.3d.up.fill"
        case .shortcuts: "keyboard.fill"
        case .tabs: "rectangle.3.group.fill"
        case .translation: "globe"
        case .about: "info.circle.fill"
        }
    }

    /// Tile colour behind the sidebar icon.
    var tint: Color {
        switch self {
        case .general: Color(nsColor: .systemGray)
        case .search: Color(nsColor: .systemBlue)
        case .appearance: Color(nsColor: .systemOrange)
        case .indexing: Color(nsColor: .systemTeal)
        case .shortcuts: Color(nsColor: .systemIndigo)
        case .tabs: Color(nsColor: .systemPurple)
        case .translation: Color(nsColor: .systemGreen)
        case .about: Color(nsColor: .systemPink)
        }
    }

    /// Words "Search settings" matches, beyond the page's own title: its rows.
    var keywords: String {
        switch self {
        case .general: "launch at login startup log level config file reset"
        case .search: "file manager finder explorer open folders external drives ssd usb suggestions empty recent web google"
        case .appearance: "corner radius liquid glass blur theme look"
        case .indexing: "scan scope depth limit lazy folders skipped extra index files everything"
        case .shortcuts: "hotkey keyboard key combination launcher clipboard quick look"
        case .tabs: "tab order clipboard dictionary translate processes ocr"
        case .translation: "languages translate dictionary"
        case .about: "version update check"
        }
    }
}

struct ThemeSettingsView: View {
    /// Outcome carried with the text so a failed save cannot be styled as a
    /// success by a stale flag.
    struct SaveMessage {
        let text: String
        let succeeded: Bool
    }

    nonisolated(unsafe) static var initialPane: SettingsPane = .general
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
    /// The page shown on the right, picked in the sidebar.
    @State var selectedPane: SettingsPane = ThemeSettingsView.initialPane
    /// The page a new Settings view starts on (set by `--render-settings` to draw a given page).
    /// "Search settings" text: narrows the sidebar to the pages that mention it.
    @State var settingsSearch = ""

    /// Pages matching the search box (all of them when it is empty).
    var visiblePanes: [SettingsPane] {
        let needle = settingsSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return SettingsPane.allCases }
        return SettingsPane.allCases.filter {
            $0.title.lowercased().contains(needle) || $0.keywords.contains(needle)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            settingsSidebar
                .frame(width: 196)
            settingsDetail
        }
        .onChange(of: settingsSearch) {
            // Typing in the search box jumps to the first page that matches.
            if let first = visiblePanes.first, !visiblePanes.contains(selectedPane) { selectedPane = first }
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

    /// Sidebar: a search box, then one entry per page with a coloured icon tile.
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(themeStore.secondaryTextColor())
                TextField("Search settings", text: $settingsSearch)
                    .textFieldStyle(.plain)
                    .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(themeStore.liftColor(opacity: 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.bottom, 8)

            ForEach(visiblePanes) { pane in
                SettingsSidebarItem(pane: pane, selected: pane == selectedPane) { selectedPane = pane }
            }
            if visiblePanes.isEmpty {
                Text("No settings match")
                    .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                    .foregroundStyle(themeStore.mutedTextColor())
                    .padding(.leading, 6)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    /// Right side: "Settings › Page" on top with the save buttons, the page's cards below.
    private var settingsDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Settings")
                        .foregroundStyle(themeStore.secondaryTextColor())
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(themeStore.mutedTextColor())
                    Text(selectedPane.title)
                        .foregroundStyle(themeStore.fontColor())
                }
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize + 9), weight: .semibold))
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
    }

    /// Segmented-looking row of option buttons; `selected` nil = none matches (custom values).
    func presetButtons(options: [String], selected: Int?, onPick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let isActive = selected == index
                Button {
                    onPick(index)
                } label: {
                    Text(options[index])
                        .lineLimit(1)
                        .fixedSize()
                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? themeStore.fontColor() : themeStore.secondaryTextColor())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            themeStore.liftColor(opacity: isActive ? Self.activeFillOpacity : 0),
                            in: RoundedRectangle(cornerRadius: themeStore.controlRadius - 2, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            themeStore.liftColor(opacity: Self.inactiveFillOpacity),
            in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
        )
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
            // Recording a shortcut: every key (Esc included) belongs to the recorder.
            guard !ShortcutSettingsSection.isRecording else { return event }

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

/// One page in the Settings sidebar: coloured icon tile + name, with Fluent's accent bar and
/// a filled background when selected.
private struct SettingsSidebarItem: View {
    @EnvironmentObject var themeStore: ThemeStore
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(selected ? Color.accentColor : .clear)
                    .frame(width: 3, height: 16)
                Image(systemName: pane.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(pane.title)
                    .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize), weight: selected ? .semibold : .regular))
                    .foregroundStyle(themeStore.fontColor())
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.trailing, 8)
            .background(
                themeStore.liftColor(opacity: selected ? 0.1 : (hovering ? 0.05 : 0)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
