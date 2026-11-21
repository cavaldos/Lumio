import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ThemeSettingsView {
    // MARK: - Preset values (one tap instead of a slider / number field)

    /// Depth 1...12, limit 500...50_000. Balanced matches the app defaults.
    private var indexingScopePresets: [(title: String, depth: Int, limit: Int)] {
        [
            (title: "Fast", depth: 2, limit: 1000),
            (title: "Balanced", depth: 4, limit: 4000),
            (title: "Thorough", depth: 8, limit: 15000),
            // Every folder level and the most files the index holds: find anything.
            (title: "Everything", depth: 12, limit: 50000),
        ]
    }

    var settingsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                // One page at a time, picked in the sidebar.
                VStack(alignment: .leading, spacing: 8) {
                    switch selectedPane {
                    case .general: generalSection
                    case .search: searchSection
                    case .appearance: appearanceSection
                    case .indexing: indexingSection
                    case .shortcuts: shortcutsSection
                    case .tabs: tabsSection
                    case .clipboard: clipboardSection
                    case .translation: translationSection
                    }
                }
                .padding(.bottom, 8)
            }
            .onAppear { syncIndexingInputsFromSettings() }
            .onChange(of: settings.fileScanDepth) { _, _ in
                fileScanDepthInput = String(settings.fileScanDepth)
            }
            .onChange(of: settings.fileScanLimit) { _, _ in
                fileScanLimitInput = String(settings.fileScanLimit)
            }
            .onChange(of: settings.clipboardHistoryLimit) { _, _ in
                clipboardHistoryLimitInput = String(settings.clipboardHistoryLimit)
            }
            .onChange(of: settings.clipboardImageLimit) { _, _ in
                clipboardImageLimitInput = String(settings.clipboardImageLimit)
            }

            Text(HintText.Settings.advancedApply)
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                .foregroundStyle(themeStore.mutedTextColor())
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var appearanceSection: some View {
        SettingsSectionTitle("Launcher")
        SettingsCard {
            SettingsRow("Corner radius", icon: "square.dashed", detail: "0% is square, 100% is fully round") {
                HStack(spacing: 10) {
                    Slider(value: $settings.launcherCornerRadius, in: ThemeSettings.cornerRadiusRange, step: 1)
                        .controlSize(.small)
                        .frame(width: 180)
                    Text("\(Int(settings.launcherCornerRadius))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
                        .foregroundStyle(themeStore.secondaryTextColor())
                }
            }
            SettingsDivider()
            SettingsToggleRow(
                "Liquid Glass", icon: "drop",
                detail: "macOS 26+. Off uses the classic blur",
                isOn: $settings.liquidGlassEnabled
            )
        }
    }

    @ViewBuilder
    private var indexingSection: some View {
        SettingsSectionTitle("Status")
        SettingsCard {
            IndexStatusRows()
        }
        SettingsSectionTitle("How much to index")
        SettingsCard {
            SettingsRow("Scan scope", icon: "scope", detail: "Fast scans less; Everything indexes every folder level, so any file can be found") {
                presetButtons(
                    options: indexingScopePresets.map { $0.title },
                    selected: indexingScopePresets.firstIndex(where: {
                        $0.depth == settings.fileScanDepth && $0.limit == settings.fileScanLimit
                    }),
                    onPick: {
                        settings.fileScanDepth = indexingScopePresets[$0].depth
                        settings.fileScanLimit = indexingScopePresets[$0].limit
                        fileScanDepthError = nil
                        fileScanLimitError = nil
                        syncIndexingInputsFromSettings()
                    }
                )
            }
            SettingsDivider()
            SettingsToggleRow(
                "Lazy indexing", icon: "arrow.triangle.2.circlepath",
                detail: "Refresh the index when the launcher opens after file or app changes",
                isOn: $settings.lazyIndexingEnabled
            )
            SettingsDivider()
            SettingsRow(
                "File scan depth", icon: "arrow.down.to.line",
                detail: fileScanDepthError ?? "How many directory levels to index (\(AppConstants.FileScan.minDepth)-\(AppConstants.FileScan.maxDepth))"
            ) {
                TextField("4", text: $fileScanDepthInput)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: fileScanDepthInput) { _, value in
                        fileScanDepthInput = sanitizedNumericInput(value)
                        if let parsed = Int(fileScanDepthInput) {
                            if parsed >= AppConstants.FileScan.minDepth && parsed <= AppConstants.FileScan.maxDepth {
                                settings.fileScanDepth = parsed
                                fileScanDepthError = nil
                            } else {
                                fileScanDepthError = "Must be \(AppConstants.FileScan.minDepth)-\(AppConstants.FileScan.maxDepth)"
                            }
                        }
                    }
            }
            SettingsDivider()
            SettingsRow(
                "File scan limit", icon: "number",
                detail: fileScanLimitError ?? "Max files indexed per refresh"
            ) {
                TextField("4000", text: $fileScanLimitInput)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: fileScanLimitInput) { _, value in
                        fileScanLimitInput = sanitizedNumericInput(value)
                        if let parsed = Int(fileScanLimitInput) {
                            if parsed >= AppConstants.FileScan.minLimit && parsed <= AppConstants.FileScan.maxLimit {
                                settings.fileScanLimit = parsed
                                fileScanLimitError = nil
                            } else {
                                fileScanLimitError = "Must be \(AppConstants.FileScan.minLimit)-\(AppConstants.FileScan.maxLimit)"
                            }
                        }
                    }
            }
        }
        SettingsSectionTitle("Folders")
        SettingsCard {
            SettingsRow("Extra scan folders", icon: "folder.badge.plus", detail: extraScanDirectoryMessage ?? "Index these folders too") {
                Button("Add Folder…") { selectExtraScanDirectory() }
            } below: {
                pathChips(themeStore.extraFileScanRoots) { path in
                    themeStore.removeExtraFileScanRoot(path)
                    extraScanDirectoryMessage = nil
                }
            }
            SettingsDivider()
            SettingsRow("Skipped folders", icon: "folder.badge.minus", detail: "Never index anything inside these") {
                Button("Add Folder…") { selectExcludedFolderPath() }
            } below: {
                pathChips(themeStore.excludedFolderPaths) { path in
                    themeStore.removeExcludedFolderPath(path)
                }
            }
        }
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        SettingsSectionTitle("Keyboard")
        ShortcutSettingsSection(settings: $settings)
    }

    @ViewBuilder
    private var tabsSection: some View {
        SettingsSectionTitle("Launcher tabs")
        SettingsCard {
            tabOrderRow
        }
        SettingsSectionTitle("Round buttons")
        SettingsCard {
            quickBubblesRow
        }
    }

    @ViewBuilder
    private var clipboardSection: some View {
        SettingsSectionTitle("Clipboard")
        SettingsCard {
            SettingsRow(
                "Clips to keep",
                detail: clipboardHistoryLimitError
                    ?? "Text clips, \(ClipboardLimits.textRange.lowerBound)-\(ClipboardLimits.textRange.upperBound). Older ones are deleted; pinned clips stay"
            ) {
                TextField("\(ClipboardLimits.Text.maxEntries)", text: $clipboardHistoryLimitInput)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: clipboardHistoryLimitInput) { _, value in
                        clipboardHistoryLimitInput = sanitizedNumericInput(value)
                        if let parsed = Int(clipboardHistoryLimitInput) {
                            if ClipboardLimits.textRange.contains(parsed) {
                                settings.clipboardHistoryLimit = parsed
                                clipboardHistoryLimitError = nil
                            } else {
                                clipboardHistoryLimitError = "Must be \(ClipboardLimits.textRange.lowerBound)-\(ClipboardLimits.textRange.upperBound)"
                            }
                        }
                    }
            }
            SettingsDivider()
            SettingsRow(
                "Images to keep",
                detail: clipboardImageLimitError
                    ?? "Image clips, \(ClipboardLimits.imageRange.lowerBound)-\(ClipboardLimits.imageRange.upperBound). Each one is a file on disk"
            ) {
                TextField("\(ClipboardLimits.Image.maxEntries)", text: $clipboardImageLimitInput)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: clipboardImageLimitInput) { _, value in
                        clipboardImageLimitInput = sanitizedNumericInput(value)
                        if let parsed = Int(clipboardImageLimitInput) {
                            if ClipboardLimits.imageRange.contains(parsed) {
                                settings.clipboardImageLimit = parsed
                                clipboardImageLimitError = nil
                            } else {
                                clipboardImageLimitError = "Must be \(ClipboardLimits.imageRange.lowerBound)-\(ClipboardLimits.imageRange.upperBound)"
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var translationSection: some View {
        SettingsSectionTitle("Languages")
        SettingsCard {
            translationLanguagesRow
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        SettingsSectionTitle("About")
        SettingsCard {
            AppUpdateStatusView(themeStore: themeStore)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        SettingsSectionTitle("Startup")
        SettingsCard {
            SettingsToggleRow(
                "Launch at login", icon: "power",
                detail: "Start Lumio automatically when you sign in",
                isOn: $settings.launchAtLogin
            )
        }
        SettingsSectionTitle("Permissions")
        SettingsCard {
            AccessibilityStatusRow()
        }
        SettingsSectionTitle("Advanced")
        SettingsCard {
            SettingsRow("Log level", icon: "doc.text.magnifyingglass", detail: "Error only by default; use Info or Debug for troubleshooting") {
                presetButtons(
                    options: BackendLogLevel.allCases.map { $0.title },
                    selected: BackendLogLevel.allCases.firstIndex(of: settings.backendLogLevel),
                    onPick: { settings.backendLogLevel = BackendLogLevel.allCases[$0] }
                )
            }
            SettingsDivider()
            SettingsRow(
                "Config file", icon: "doc.badge.gearshape",
                detail: freshConfigMessage ?? "Replace the config file with a fresh default one"
            ) {
                Button("Create Fresh Config…") {
                    showFreshConfigConfirm = true
                    freshConfigMessage = nil
                }
            }
        }
    }

    /// Search page: what the launcher shows and where it looks. These apply at once (no Save).
    @ViewBuilder
    private var searchSection: some View {
        SettingsSectionTitle("Results")
        SettingsCard {
            LauncherSuggestionRows()
            SettingsDivider()
            KeepSearchSettingsRow()
            SettingsDivider()
            LearningSettingsRow()
            SettingsDivider()
            ConfigListSettingsRow(
                title: "Rank these file types last", icon: "arrow.down.to.line.compact",
                detail: "File endings that sink below everything else, separated by commas. Empty the box and press Save to rank every file the same",
                key: SpotlightFiles.lowPriorityConfigKey,
                fallback: SpotlightFiles.defaultLowPriorityExtensions.sorted().joined(separator: ", ")
            )
            SettingsDivider()
            ConfigListSettingsRow(
                title: "Extra web search rows", icon: "globe",
                detail: "Tag keywords (yt, bing, w, amz…) that get their own row under \"Search the web\" for anything you type",
                key: SpotlightBackend.extraWebRowsKey, fallback: "", placeholder: "e.g. yt, bing"
            )
        }
        SettingsSectionTitle("Files and folders")
        SettingsCard {
            FileManagerSettingsRow()
            SettingsDivider()
            ExternalDrivesSettingsRow()
        }
    }

    /// Removable path chips under a folder row; nothing when the list is empty.
    @ViewBuilder
    private func pathChips(_ paths: [String], onRemove: @escaping (String) -> Void) -> some View {
        if !paths.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 6) {
                            Text(path)
                                .lineLimit(1)
                            Button {
                                withAnimation(Motion.Insert.animation) { onRemove(path) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                        .foregroundStyle(themeStore.secondaryTextColor())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(themeStore.liftColor(opacity: 0.1), in: Capsule())
                        .transition(Motion.Insert.transition)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The launcher's tool tabs in their current order, each with arrows to move it.
    var tabOrderRow: some View {
        let order = TabOrder.normalized(settings.tabOrder)
        return SettingsRow(
            "Tab order", icon: "rectangle.3.group",
            detail: "Order of the tabs after All in the launcher. The eye hides a tab from the pill row and from Tab"
        ) {
            if order != TabOrder.defaultCodes || !settings.hiddenTabs.isEmpty {
                Button("Reset") {
                    settings.tabOrder = TabOrder.defaultCodes
                    settings.hiddenTabs = []
                }
            }
        } below: {
            HStack(spacing: 8) {
                ForEach(Array(order.enumerated()), id: \.element) { index, code in
                    tabOrderChip(code: code, isFirst: index == 0, isLast: index == order.count - 1)
                }
            }
        }
    }

    private func tabOrderChip(code: String, isFirst: Bool, isLast: Bool) -> some View {
        let shown = !settings.hiddenTabs.contains(code)
        return HStack(spacing: 4) {
            tabOrderArrow("chevron.left", disabled: isFirst) {
                settings.tabOrder = TabOrder.moving(code, by: -1, in: settings.tabOrder)
            }
            Text(SpotlightKind(rawValue: code)?.tabLabel ?? code)
                .lineLimit(1)
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .semibold))
                .foregroundStyle(themeStore.fontColor())
                .strikethrough(!shown)
                .opacity(shown ? 1 : 0.45)
                // The chips share the row, so long names get cut: hover shows the whole name.
                .help(SpotlightKind(rawValue: code)?.tabLabel ?? code)
            tabOrderArrow(shown ? "eye" : "eye.slash", disabled: false) {
                settings.hiddenTabs = TabOrder.setting(code, shown: !shown, in: settings.hiddenTabs)
            }
            .help(shown ? "Hide this tab" : "Show this tab")
            tabOrderArrow("chevron.right", disabled: isLast) {
                settings.tabOrder = TabOrder.moving(code, by: 1, in: settings.tabOrder)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            themeStore.liftColor(opacity: Self.activeFillOpacity),
            in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
        )
    }

    /// The idle bar's round buttons: what each one opens (menu) and their order (arrows).
    var quickBubblesRow: some View {
        let slots = QuickBubbles.normalized(settings.quickBubbles)
        return SettingsRow(
            "Round buttons", icon: "circle.grid.2x2",
            detail: "What the 4 buttons beside the empty search bar open, in order (⌘1-⌘4)"
        ) {
            if slots != QuickBubbles.defaultCodes {
                Button("Reset") {
                    settings.quickBubbles = QuickBubbles.defaultCodes
                }
            }
        } below: {
            HStack(spacing: 8) {
                ForEach(Array(slots.enumerated()), id: \.offset) { index, code in
                    quickBubbleChip(slot: index, code: code, isLast: index == slots.count - 1)
                }
            }
        }
    }

    private func quickBubbleChip(slot: Int, code: String, isLast: Bool) -> some View {
        let kind = SpotlightKind(rawValue: code)
        return HStack(spacing: 4) {
            tabOrderArrow("chevron.left", disabled: slot == 0) {
                settings.quickBubbles = QuickBubbles.moving(slot: slot, by: -1, in: settings.quickBubbles)
            }
            Menu {
                ForEach(QuickBubbles.choices, id: \.self) { choice in
                    let option = SpotlightKind(rawValue: choice)
                    Button {
                        settings.quickBubbles = QuickBubbles.setting(slot: slot, to: choice, in: settings.quickBubbles)
                    } label: {
                        Label(option?.quickLabel ?? choice, systemImage: choice == code ? "checkmark" : (option?.quickIcon ?? "circle"))
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: kind?.quickIcon ?? "circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(kind?.quickLabel ?? code)
                        .lineLimit(1)
                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(themeStore.secondaryTextColor())
                }
                .foregroundStyle(themeStore.fontColor())
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("⌘\(slot + 1): \(kind?.quickLabel ?? code) (click to change)")
            tabOrderArrow("chevron.right", disabled: isLast) {
                settings.quickBubbles = QuickBubbles.moving(slot: slot, by: 1, in: settings.quickBubbles)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            themeStore.liftColor(opacity: Self.activeFillOpacity),
            in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
        )
    }

    private func tabOrderArrow(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(themeStore.secondaryTextColor())
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
    }

    /// Language chips for tr" / tw": tap to add or remove, 1-5 at a time.
    var translationLanguagesRow: some View {
        let chosen = Set(TranslationLanguage.selected(settings.translationLanguages).map(\.code))
        let atMax = chosen.count >= TranslationLanguage.maxSelected
        let atMin = chosen.count <= TranslationLanguage.minSelected
        return SettingsRow(
            "Languages", icon: "globe",
            detail: "Pick \(TranslationLanguage.minSelected)-\(TranslationLanguage.maxSelected) languages to translate into (tr\" and tw\")"
        ) {
            if Set(TranslationLanguage.defaultCodes) != chosen {
                Button("Reset to VI · EN · FR") {
                    settings.translationLanguages = TranslationLanguage.defaultCodes
                }
            }
        } below: {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(TranslationLanguage.supported) { language in
                        let isOn = chosen.contains(language.code)
                        let locked = isOn ? atMin : atMax
                        Button {
                            toggleTranslationLanguage(language.code, chosen: chosen)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("\(language.name)")
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(language.shortCode)
                                    .foregroundStyle(themeStore.mutedTextColor())
                            }
                            .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? themeStore.fontColor() : themeStore.secondaryTextColor())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                themeStore.liftColor(opacity: isOn ? Self.activeFillOpacity : Self.inactiveFillOpacity),
                                in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(locked)
                        .opacity(locked && !isOn ? 0.45 : 1)
                    }
                }
        }
    }

    func toggleTranslationLanguage(_ code: String, chosen: Set<String>) {
        var next = chosen
        if next.contains(code) {
            guard next.count > TranslationLanguage.minSelected else { return }
            next.remove(code)
        } else {
            guard next.count < TranslationLanguage.maxSelected else { return }
            next.insert(code)
        }
        // Keep the catalog's display order.
        settings.translationLanguages = TranslationLanguage.supported.map(\.code).filter(next.contains)
    }

    func selectExcludedFolderPath() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            withAnimation(Motion.Insert.animation) {
                themeStore.addExcludedFolderPath(url: url)
            }
        }
    }

    func selectExtraScanDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            withAnimation(Motion.Insert.animation) {
                if let error = themeStore.addExtraFileScanRoot(url: url) {
                    extraScanDirectoryMessage = error.message
                } else {
                    extraScanDirectoryMessage = nil
                }
            }
        }
    }

    func syncIndexingInputsFromSettings() {
        fileScanDepthInput = String(settings.fileScanDepth)
        fileScanLimitInput = String(settings.fileScanLimit)
        clipboardHistoryLimitInput = String(settings.clipboardHistoryLimit)
        clipboardImageLimitInput = String(settings.clipboardImageLimit)
        clipboardHistoryLimitError = nil
        clipboardImageLimitError = nil
    }

    func sanitizedNumericInput(_ value: String) -> String {
        String(value.filter(\.isNumber))
    }

    func applyFileScanDepthInput() {
        guard let parsed = Int(fileScanDepthInput), parsed > 0 else {
            fileScanDepthInput = String(settings.fileScanDepth)
            return
        }
        settings.fileScanDepth = min(max(1, parsed), 12)
        fileScanDepthInput = String(settings.fileScanDepth)
    }

    func applyFileScanLimitInput() {
        guard let parsed = Int(fileScanLimitInput), parsed > 0 else {
            fileScanLimitInput = String(settings.fileScanLimit)
            return
        }
        settings.fileScanLimit = min(max(500, parsed), 50_000)
        fileScanLimitInput = String(settings.fileScanLimit)
    }

    /// Save with a typed value still out of range (or empty) puts back the last valid one
    /// instead of saving it, like the scan inputs above.
    func applyClipboardLimitInputs() {
        if let parsed = Int(clipboardHistoryLimitInput), ClipboardLimits.textRange.contains(parsed) {
            settings.clipboardHistoryLimit = parsed
        }
        if let parsed = Int(clipboardImageLimitInput), ClipboardLimits.imageRange.contains(parsed) {
            settings.clipboardImageLimit = parsed
        }
        clipboardHistoryLimitInput = String(settings.clipboardHistoryLimit)
        clipboardImageLimitInput = String(settings.clipboardImageLimit)
    }

    func runFreshConfigReset() {
        let ok = themeStore.regenerateFreshConfigFile()
        syncIndexingInputsFromSettings()
        freshConfigMessage = ok ? "Fresh config created" : "Failed to recreate config"
        if ok {
            NotificationCenter.default.post(name: .lookReloadConfigRequested, object: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            freshConfigMessage = nil
        }
    }

    /// A typed value outside its range: Save stays off until it is fixed.
    var hasInputError: Bool {
        fileScanDepthError != nil || fileScanLimitError != nil
            || clipboardHistoryLimitError != nil || clipboardImageLimitError != nil
    }
}

/// "Open folders in": Finder or any third-party file manager on this Mac. Writes
/// `file_manager=` to the config; used by ⏎ on folders, ⌘F and "Show in …".
struct FileManagerSettingsRow: View {
    @State private var choice = FileManagerApp.choice
    @State private var options = FileManagerApp.options()

    var body: some View {
        SettingsRow(
            "Open folders in", icon: "folder",
            detail: "Folders open and ⌘F shows files in this app. Automatic follows the system file viewer"
        ) {
            Picker("Open folders in", selection: Binding(
                get: { options.first { $0.value.caseInsensitiveCompare(choice) == .orderedSame }?.value ?? "auto" },
                set: { value in
                    if FileManagerApp.setChoice(value) { choice = value }
                }
            )) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .onAppear {
            choice = FileManagerApp.choice
            options = FileManagerApp.options()
        }
    }
}

/// Reads and writes single `key=value` lines of ~/.lumio/config for the settings below
/// (the rest of the file is left exactly as it is), then asks the launcher to reload.
enum LauncherConfigFile {
    static func value(_ key: String) -> String? {
        let raw = (try? String(contentsOfFile: ConfigPathResolver.resolvedPath(), encoding: .utf8)) ?? ""
        return SearchTags.configLines(raw).last(where: { $0.0 == key })?.1
    }

    @discardableResult
    static func set(_ key: String, to value: String) -> Bool {
        let path = ConfigPathResolver.resolvedPath()
        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var lines = ConfigFileLines.parse(raw)
        ConfigFileLines.upsert(&lines, key: key, value: value)
        do {
            try ConfigFileLines.render(lines).write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        NotificationCenter.default.post(name: .lookReloadConfigRequested, object: nil)
        return true
    }
}

/// Plugged-in drives in file search, with the drives connected right now named in the row.
struct ExternalDrivesSettingsRow: View {
    @State private var externalDrives = ExternalDrives.isEnabled
    @State private var driveNames: [String] = []

    /// "Connected now: T7, Backup" so it is obvious what the switch covers.
    private var drivesDetail: String {
        let base = "Find files on plugged-in SSDs, USB sticks and SD cards, with nothing to set up. "
        return base + (driveNames.isEmpty ? "No drive is connected right now"
            : "Connected now: " + driveNames.joined(separator: ", "))
    }

    var body: some View {
        SettingsToggleRow(
            "Search external drives", icon: "externaldrive",
            detail: drivesDetail,
            isOn: Binding(
                get: { externalDrives },
                set: { value in
                    if LauncherConfigFile.set(ExternalDrives.configKey, to: value ? "true" : "false") {
                        externalDrives = value
                        ExternalDrives.isEnabled = value
                    }
                }
            )
        )
        .onAppear {
            externalDrives = LauncherConfigFile.value(ExternalDrives.configKey).map {
                !["false", "0", "no", "off"].contains($0.lowercased())
            } ?? true
            driveNames = ExternalDrives.mounted().map(\.name)
        }
    }
}

/// Suggestions on the empty field, and web suggestions while typing.
struct LauncherSuggestionRows: View {
    @State private var suggestionsOnOpen = RecentItems.isEnabled
    @State private var webMode = WebSuggestions.mode

    var body: some View {
        SettingsToggleRow(
            "Suggestions when empty", icon: "sparkles",
            detail: "Show the apps and files you use most before you type. Off brings back the four round buttons",
            isOn: Binding(
                get: { suggestionsOnOpen },
                set: { value in
                    if LauncherConfigFile.set(RecentItems.configKey, to: value ? "true" : "false") {
                        suggestionsOnOpen = value
                    }
                }
            )
        )
        SettingsDivider()
        SettingsRow(
            "Web suggestions", icon: "magnifyingglass",
            detail: "Google's suggestions as you type. This sends the typed text to Google; \"In tags\" limits it to web search tags"
        ) {
            Picker("Web suggestions", selection: Binding(
                get: { webMode },
                set: { value in
                    if LauncherConfigFile.set(WebSuggestions.configKey, to: value.rawValue) { webMode = value }
                }
            )) {
                Text("Always").tag(WebSuggestions.Mode.always)
                Text("In tags").tag(WebSuggestions.Mode.tags)
                Text("Off").tag(WebSuggestions.Mode.off)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .onAppear {
            suggestionsOnOpen = RecentItems.isEnabled
            webMode = WebSuggestions.mode
        }
    }
}

/// Settings ▸ Indexing ▸ Status: what the index holds, when it was updated, and Rebuild.
struct IndexStatusRows: View {
    @State private var stats: IndexStats?
    @State private var rebuilding = false
    @State private var outcome: String?

    private var countsLine: String {
        guard let stats else { return "Reading the index…" }
        guard stats.total > 0 else { return "The index is empty. Press Rebuild" }
        var line = "\(stats.files.formatted()) files, \(stats.folders.formatted()) folders and \(stats.apps.formatted()) apps"
        if let updated = stats.updated {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            line += ". Updated \(formatter.localizedString(for: updated, relativeTo: Date()))"
        }
        return line
    }

    private var spotlightLine: String {
        switch stats?.spotlightOn {
        case true?: "On. Files anywhere in your home folder, iCloud Drive and plugged-in drives are found through it, with no limit"
        case false?: "Off. Only the files in Lumio's own index can be found until Spotlight is turned back on in System Settings"
        case nil: stats == nil ? "Checking…" : "Couldn't check"
        }
    }

    var body: some View {
        SettingsRow("Lumio's index", icon: "square.stack.3d.up", detail: outcome ?? countsLine) {
            Button(rebuilding ? "Rebuilding…" : "Rebuild") { rebuild() }
                .disabled(rebuilding)
        }
        SettingsDivider()
        SettingsRow("macOS Spotlight index", icon: "magnifyingglass.circle", detail: spotlightLine) {
            EmptyView()
        }
        .task { await load() }
    }

    private func load() async {
        stats = await Task.detached(priority: .userInitiated) { IndexStats.read() }.value
    }

    /// Walks every indexed folder again and replaces the index (the same work a config
    /// reload does), then shows the new counts.
    private func rebuild() {
        rebuilding = true
        outcome = "Scanning your folders…"
        Task { @MainActor in
            let started = Date()
            let ok = await EngineBridge.shared.reloadConfigInBackground()
            await load()
            rebuilding = false
            let seconds = Date().timeIntervalSince(started)
            outcome = ok
                ? "Rebuilt in \(String(format: "%.1f", seconds)) s: \((stats?.total ?? 0).formatted()) items"
                : "The rebuild failed. Lumio keeps using the previous index"
        }
    }
}

/// Whether the Accessibility permission works, is off, or has gone stale (switch on, macOS
/// ignoring it), with a button that opens the dialog explaining it and offering the fix.
struct AccessibilityStatusRow: View {
    @State private var state: AccessibilityAccess.State?

    private var line: String {
        switch state {
        case nil: "Checking…"
        case .working?: "Working. Used for window search and for looking up the selected text"
        case .off(listed: true)?: "Off. Lumio is in the macOS list, but its switch is off"
        case .off(listed: false)?: "Off. Window search and looking up the selected text need it"
        case .stale(.allowedButRefused)?: "Stale: allowed, but macOS refuses Lumio until it is reopened"
        case .stale(.switchOnButIgnored)?: "Stale: the switch is on in System Settings, but macOS is ignoring it"
        case .stale(.workedBefore)?: "Probably stale: it worked before and has stopped"
        }
    }

    private var icon: String {
        switch state {
        case .working?: "checkmark.shield"
        case .stale?: "exclamationmark.shield"
        default: "shield"
        }
    }

    var body: some View {
        SettingsRow("Accessibility", icon: icon, detail: line) {
            Button(buttonTitle) { AccessibilityDoctor.shared.showStatus() }
                .fixedSize()
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: AccessibilityDoctor.changed)) { _ in reload() }
        // Coming back from System Settings: the switch may have been flipped.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private var buttonTitle: String {
        switch state {
        case .stale?: "Fix…"
        case .off?: "Turn On…"
        default: "Check"
        }
    }

    private func reload() {
        AccessibilityDoctor.shared.check { state = $0 }
    }
}

/// A comma-separated list kept in the config file, edited in a text box with a Save button.
struct ConfigListSettingsRow: View {
    let title: String
    let icon: String
    let detail: String
    let key: String
    /// Shown when the config has no line for `key`.
    let fallback: String
    var placeholder = "none"

    @State private var text = ""
    @State private var saved = ""

    var body: some View {
        SettingsRow(title, icon: icon, detail: detail) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit { save() }
                Button("Save") { save() }
                    .fixedSize()
                    .disabled(text == saved)
            }
        }
        .onAppear {
            saved = LauncherConfigFile.value(key) ?? fallback
            text = saved
        }
    }

    private func save() {
        let clean = text.split(whereSeparator: { ", ;|".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if LauncherConfigFile.set(key, to: clean) {
            saved = clean
            text = clean
        }
    }
}

/// How long a dismissed search (text and tags) comes back when the launcher is reopened
/// (Fluent's "Reset search after it was hidden for set seconds", 30 by default).
struct KeepSearchSettingsRow: View {
    @State private var seconds = KeepSearchSettingsRow.current()

    private static let choices: [(label: String, seconds: Int)] = [
        ("Off", 0), ("5 seconds", 5), ("30 seconds", 30), ("2 minutes", 120), ("5 minutes", 300),
        ("Always", AppConstants.Launcher.QueryRetention.never),
    ]

    private static func current() -> Int {
        guard let raw = LauncherConfigFile.value(AppConstants.Launcher.QueryRetention.configKey) else {
            return AppConstants.Launcher.QueryRetention.defaultSeconds
        }
        return QueryRetentionPolicy.resolveSeconds(from: [AppConstants.Launcher.QueryRetention.configKey: raw])
    }

    var body: some View {
        SettingsRow(
            "Keep last search", icon: "clock.arrow.circlepath",
            detail: "Close the launcher and reopen it within this time to find your text and tags still there, selected so typing replaces them"
        ) {
            Picker("Keep last search", selection: Binding(
                get: { seconds },
                set: { value in
                    if LauncherConfigFile.set(AppConstants.Launcher.QueryRetention.configKey, to: String(value)) {
                        seconds = value
                    }
                }
            )) {
                ForEach(Self.choices, id: \.seconds) { choice in
                    Text(choice.label).tag(choice.seconds)
                }
                // A number written by hand in the config file.
                if !Self.choices.contains(where: { $0.seconds == seconds }) {
                    Text("\(seconds) seconds").tag(seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .onAppear { seconds = Self.current() }
    }
}

/// What Lumio has learned from your picks, with a button to forget it (Fluent's
/// "Reset learning data").
struct LearningSettingsRow: View {
    @State private var count = UsageLearning.shared.count

    var body: some View {
        SettingsRow(
            "Learned results", icon: "brain",
            detail: "Lumio remembers what you open for each search and offers it first. "
                + (count == 0 ? "Nothing learned yet" : "\(count) results remembered")
        ) {
            Button("Reset") {
                UsageLearning.shared.reset()
                count = 0
            }
            .disabled(count == 0)
        }
        .onAppear { count = UsageLearning.shared.count }
    }
}
