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
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Indexing")

                    presetRow(
                        title: "Scan Scope",
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
                    .help("Fast scans less, Thorough scans deeper. Exact numbers live under Indexing details.")

                    Toggle(isOn: $settings.lazyIndexingEnabled) {
                        HStack(spacing: 10) {
                            Text("Lazy indexing")
                                .frame(width: AppConstants.ThemeUI.labelWidth, alignment: .leading)
                                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
                            Text("Refresh index automatically when launcher opens after file/app changes")
                                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                                .foregroundStyle(themeStore.mutedTextColor())
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Text("File Scan Depth")
                                    .frame(width: AppConstants.ThemeUI.labelWidth, alignment: .leading)
                                    .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
                                    .foregroundStyle(themeStore.secondaryTextColor())

                                TextField("4", text: $fileScanDepthInput)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80, alignment: .leading)
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
                                    .help("Valid: \(AppConstants.FileScan.minDepth)-\(AppConstants.FileScan.maxDepth)")

                                if let error = fileScanDepthError {
                                    Text(error)
                                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                                        .foregroundStyle(themeStore.dangerColor())
                                }

                                Text("How many directory levels to index")
                                    .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                                    .foregroundStyle(themeStore.mutedTextColor())
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            HStack(spacing: 10) {
                                Text("File Scan Limit")
                                    .frame(width: AppConstants.ThemeUI.labelWidth, alignment: .leading)
                                    .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
                                    .foregroundStyle(themeStore.secondaryTextColor())

                                TextField("4000", text: $fileScanLimitInput)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100, alignment: .leading)
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

                                if let error = fileScanLimitError {
                                    Text(error)
                                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                                        .foregroundStyle(themeStore.dangerColor())
                                }

                                Text("Max files indexed per refresh")
                                    .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                                    .foregroundStyle(themeStore.mutedTextColor())
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Indexing details")
                            .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .semibold))
                            .foregroundStyle(themeStore.secondaryTextColor())
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Text("Extra Scan Dirs")
                            .frame(width: AppConstants.ThemeUI.labelWidth, alignment: .leading)
                            .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
                            .foregroundStyle(themeStore.secondaryTextColor())

                        VStack(alignment: .leading, spacing: 8) {
                            Button("Add Directory") {
                                selectExtraScanDirectory()
                            }

                            if themeStore.extraFileScanRoots.isEmpty {
                                Text("No extra scan directories")
                                    .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                                    .foregroundStyle(themeStore.mutedTextColor())
                            } else {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 8) {
                                        ForEach(themeStore.extraFileScanRoots, id: \.self) { path in
                                            HStack(spacing: 6) {
                                                Text(path)
                                                    .lineLimit(1)
                                                Button {
                                                    withAnimation(Motion.Insert.animation) {
                                                        themeStore.removeExtraFileScanRoot(path)
                                                        extraScanDirectoryMessage = nil
                                                    }
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 10, weight: .semibold))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                                            .foregroundStyle(themeStore.secondaryTextColor())
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 5)
                                            .background(themeStore.liftColor(opacity: 0.12), in: Capsule())
                                            .transition(Motion.Insert.transition)
                                        }
                                    }
                                }
                                .scrollIndicators(.hidden)
                            }

                            if let extraScanDirectoryMessage {
                                Text(extraScanDirectoryMessage)
                                    .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                                    .foregroundStyle(themeStore.dangerColor())
                            }

                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Text("Skip Folders")
                            .frame(width: AppConstants.ThemeUI.labelWidth, alignment: .leading)
                            .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
                            .foregroundStyle(themeStore.secondaryTextColor())

                        VStack(alignment: .leading, spacing: 8) {
                            Button("Add Folder") {
                                selectExcludedFolderPath()
                            }

                            if themeStore.excludedFolderPaths.isEmpty {
                                Text("No excluded folder paths yet")
                                    .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                                    .foregroundStyle(themeStore.mutedTextColor())
                            } else {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 8) {
                                        ForEach(themeStore.excludedFolderPaths, id: \.self) { path in
                                            HStack(spacing: 6) {
                                                Text(path)
                                                    .lineLimit(1)
                                                Button {
                                                    withAnimation(Motion.Insert.animation) {
                                                        themeStore.removeExcludedFolderPath(path)
                                                    }
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 10, weight: .semibold))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                                            .foregroundStyle(themeStore.secondaryTextColor())
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 5)
                                            .background(themeStore.liftColor(opacity: 0.12), in: Capsule())
                                            .transition(Motion.Insert.transition)
                                        }
                                    }
                                }
                                .scrollIndicators(.hidden)
                            }

                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()
                        .overlay(themeStore.dividerColor())
                        .padding(.vertical, 4)

                    sectionHeader("Privacy & Logs")

                    presetRow(
                        title: "Log Level",
                        options: BackendLogLevel.allCases.map { $0.title },
                        selected: BackendLogLevel.allCases.firstIndex(of: settings.backendLogLevel),
                        onPick: { settings.backendLogLevel = BackendLogLevel.allCases[$0] }
                    )
                    .help("Error only by default; use Info/Debug for troubleshooting.")

                    Divider()
                        .overlay(themeStore.dividerColor())
                        .padding(.vertical, 4)

                    Text("Startup")
                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .semibold))
                        .foregroundStyle(themeStore.secondaryTextColor())

                    Toggle(isOn: $settings.launchAtLogin) {
                        HStack(spacing: 10) {
                            Text("Launch at login")
                                .frame(width: AppConstants.ThemeUI.labelWidth, alignment: .leading)
                                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
                            Text("Start lumio automatically when you sign in")
                                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                                .foregroundStyle(themeStore.mutedTextColor())
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Divider()
                        .overlay(themeStore.dividerColor())
                        .padding(.vertical, 4)

                    Text("Config file")
                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .semibold))
                        .foregroundStyle(themeStore.secondaryTextColor())

                    HStack(spacing: 10) {
                        Button("Create Fresh Config") {
                            showFreshConfigConfirm = true
                            freshConfigMessage = nil
                        }

                        Text("Regenerate a fresh default config file. Your current file will be replaced.")
                            .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                            .foregroundStyle(themeStore.mutedTextColor())
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let freshConfigMessage {
                            Text(freshConfigMessage)
                                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                                .foregroundStyle(themeStore.mutedTextColor())
                        }
                    }

                    Divider()
                        .overlay(themeStore.dividerColor())
                        .padding(.vertical, 4)

                    aboutSection
                        .id(Self.aboutAnchorID)

                }
            }
            .onAppear { syncIndexingInputsFromSettings() }
            .onChange(of: settings.fileScanDepth) { _, _ in
                fileScanDepthInput = String(settings.fileScanDepth)
            }
            .onChange(of: settings.fileScanLimit) { _, _ in
                fileScanLimitInput = String(settings.fileScanLimit)
            }
            }

            Spacer(minLength: 0)

            Text(HintText.Settings.advancedApply)
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                .foregroundStyle(themeStore.mutedTextColor())
        }
    }

    static let aboutAnchorID = "lumio-about-section"

    @ViewBuilder
    var aboutSection: some View {
        Text("About")
            .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .semibold))
            .foregroundStyle(themeStore.secondaryTextColor())

        AppUpdateStatusView(themeStore: themeStore)
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
