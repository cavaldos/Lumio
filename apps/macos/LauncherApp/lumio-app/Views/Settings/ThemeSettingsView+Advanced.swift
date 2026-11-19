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
        ]
    }

    var settingsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    appearanceSection
                    indexingSection
                    shortcutsSection
                    tabsSection
                    translationSection
                    generalSection
                    aboutSection
                        .id(Self.aboutAnchorID)
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

            Text(HintText.Settings.advancedApply)
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                .foregroundStyle(themeStore.mutedTextColor())
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var appearanceSection: some View {
        SettingsSectionTitle("Appearance")
        SettingsCard {
            SettingsRow("Corner radius", detail: "0% is square, 100% is fully round") {
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
                "Liquid Glass",
                detail: "macOS 26+. Off uses the classic blur",
                isOn: $settings.liquidGlassEnabled
            )
        }
    }

    @ViewBuilder
    private var indexingSection: some View {
        SettingsSectionTitle("Indexing")
        SettingsCard {
            SettingsRow("Scan scope", detail: "Fast scans less, Thorough scans deeper") {
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
                "Lazy indexing",
                detail: "Refresh the index when the launcher opens after file or app changes",
                isOn: $settings.lazyIndexingEnabled
            )
            SettingsDivider()
            SettingsRow(
                "File scan depth",
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
                "File scan limit",
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
            SettingsDivider()
            SettingsRow("Extra scan folders", detail: extraScanDirectoryMessage ?? "Index these folders too") {
                Button("Add Folder…") { selectExtraScanDirectory() }
            } below: {
                pathChips(themeStore.extraFileScanRoots) { path in
                    themeStore.removeExtraFileScanRoot(path)
                    extraScanDirectoryMessage = nil
                }
            }
            SettingsDivider()
            SettingsRow("Skipped folders", detail: "Never index anything inside these") {
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
        SettingsSectionTitle("Shortcuts")
        ShortcutSettingsSection(settings: $settings)
    }

    @ViewBuilder
    private var tabsSection: some View {
        SettingsSectionTitle("Tabs")
        SettingsCard {
            tabOrderRow
        }
    }

    @ViewBuilder
    private var translationSection: some View {
        SettingsSectionTitle("Translation")
        SettingsCard {
            translationLanguagesRow
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        SettingsSectionTitle("General")
        SettingsCard {
            SettingsToggleRow(
                "Launch at login",
                detail: "Start Lumio automatically when you sign in",
                isOn: $settings.launchAtLogin
            )
            SettingsDivider()
            SettingsRow("Log level", detail: "Error only by default; use Info or Debug for troubleshooting") {
                presetButtons(
                    options: BackendLogLevel.allCases.map { $0.title },
                    selected: BackendLogLevel.allCases.firstIndex(of: settings.backendLogLevel),
                    onPick: { settings.backendLogLevel = BackendLogLevel.allCases[$0] }
                )
            }
            SettingsDivider()
            SettingsRow(
                "Config file",
                detail: freshConfigMessage ?? "Replace the config file with a fresh default one"
            ) {
                Button("Create Fresh Config…") {
                    showFreshConfigConfirm = true
                    freshConfigMessage = nil
                }
            }
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

    static let aboutAnchorID = "lumio-about-section"

    /// The launcher's tool tabs in their current order, each with arrows to move it.
    var tabOrderRow: some View {
        let order = TabOrder.normalized(settings.tabOrder)
        return SettingsRow("Tab order", detail: "Order of the tabs after All in the launcher") {
            if order != TabOrder.defaultCodes {
                Button("Reset") {
                    settings.tabOrder = TabOrder.defaultCodes
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
        HStack(spacing: 4) {
            tabOrderArrow("chevron.left", disabled: isFirst) {
                settings.tabOrder = TabOrder.moving(code, by: -1, in: settings.tabOrder)
            }
            Text(SpotlightKind(rawValue: code)?.tabLabel ?? code)
                .lineLimit(1)
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .semibold))
                .foregroundStyle(themeStore.fontColor())
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
            "Languages",
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

    var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle("About")
            SettingsCard {
                AppUpdateStatusView(themeStore: themeStore)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
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

    var hasIndexingError: Bool {
        fileScanDepthError != nil || fileScanLimitError != nil
    }
}
