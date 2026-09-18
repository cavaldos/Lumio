import AppKit
import CoreServices
import OSLog
import SwiftUI

struct LauncherView: View {

    enum BannerStyle {
        case success
        case error
        case info
        case warning

        var background: Color {
            switch self {
            case .success:
                return .green.opacity(0.42)
            case .error:
                return .red.opacity(0.45)
            case .info:
                return .blue.opacity(0.40)
            case .warning:
                return .orange.opacity(0.45)
            }
        }
    }

    @EnvironmentObject var appUIState: AppUIState
    @EnvironmentObject var themeStore: ThemeStore
    @Environment(\.openWindow) var openWindow
    @StateObject var clipboardStore = ClipboardHistoryStore()
    /// True for the single query change caused by a submit's own input-clear
    /// (`clearQuerySilently`), so it skips re-searching over just-published results.
    @State var querySilentlyCleared = false

    @State var query = ""
    @State var commandInput = ""
    @State var isCommandMode = false
    @State var backendResults: [LauncherResult] = []
    @State var recentURLEntries: [URLHistoryEntry] = []
    @State var recentURLTask: Task<Void, Never>?
    // The Cmd+K action menu. Closed by default, so a row's verbs cost the
    // preview no space until asked for.
    @State var isActionMenuOpen = false
    @State var actionMenuIndex = 0
    @State var selectedResultID: String?

    @State var pickedKeys: [String] = []
    @State var pickedResultsByKey: [String: LauncherResult] = [:]

    static func pickedKey(for result: LauncherResult) -> String {
        "\(result.kind.rawValue)|\(result.path)"
    }
    @State var selectedCommandID: String?
    @State var activeCommandID: String?
    @State var commandFeedback = ""
    @State var keyboardMonitor = KeyboardSelectionMonitor()
    @State var speedTest = SpeedTestController()
    @State var searchTask: Task<Void, Never>?
    @State var latestSearchID: UInt64 = 0
    @State var bannerMessage: String?
    @State var bannerStyle: BannerStyle = .info
    @State var bannerCopyText: String?
    @State var bannerTask: Task<Void, Never>?
    @State var lookupPreviewTask: Task<Void, Never>?
    @State var selectedKillSuggestionIndex: Int?
    @State var pendingKillCandidate: KillCommand.Candidate?
    // nil == no empty-Trash confirmation pending; otherwise the item count to show.
    // (Moving files/folders to Trash is recoverable, so it skips confirmation;
    // only the permanent Empty Trash prompts.)
    @State var pendingEmptyTrashCount: Int?
    @State var pendingHideAppResult: LauncherResult?
    // True while a trash/empty operation is running, to block re-triggering it.
    @State var isDeleteInFlight = false
    @State var killListRefreshTick: Int = 0
    @State var recentlyKilledPIDs: Set<Int32> = []
    @State var showsHelpScreen = false
    @State var focusRequestToken: UInt64 = 0
    /// Bumped every time the launcher window is shown, so the spawn cascade
    /// replays on each open (see `Motion.Spawn`).
    @State var appearanceRevealToken: UInt64 = 0
    @State var lookupDefinition: LookupDefinition?
    @State var pidToRestoreOnHide: pid_t?
    /// Read at launch and on config reload, so the show path never touches the
    /// filesystem.
    @State var lastHiddenAt: Date?
    @State var queryRetentionSeconds = AppConstants.Launcher.QueryRetention.defaultSeconds
    @StateObject var runningAppsService = RunningAppsService()
    @StateObject var processModel = ProcessFinderModel()

    /// Live size of the whole panel, captured so a background image can be
    /// cropped into each floating tile at its correct window position (the tiles
    /// share one aligned image, cut apart by the gaps). See `tileBackground`.
    @State private var panelSize: CGSize = .zero
    static let panelCoordinateSpace = "launcherPanel"

    static let floatingTileScrimOpacity = 0.30

    /// How far the resting search slice bleeds past its layout box to reach the
    /// window edges: must equal `borderedPanel`'s content padding for the idle
    /// home state (14 horizontal, max(4, 14-8) = 6 top — command mode never
    /// rests, so its tighter padding is out of scope).
    static let restingBleedHorizontal: CGFloat = 14
    static let restingBleedTop: CGFloat = 6

    /// TEMP test: tô màu background để phân biệt 2 trạng thái.
    /// Ảnh 1 (bar lúc chưa gõ) = ĐỎ, ảnh 2 (panel lúc có result) = XANH.
    /// Xóa flag này là về lại bình thường.
    static let testTintBackgrounds = false
    /// TEMP test: nền đỏ đặc, bỏ blur kính — blur recompute mỗi frame
    /// khi resize window là nguồn khựng chính. Đúng spec componentA nền đỏ.
    static let testSolidBackground = false
    /// TEMP test: override bán kính bo góc của window (WindowConfigurator
    /// vẽ lại mỗi lần update nên phải đi đường shared state này).
    /// nil = dùng panelRadius như cũ.
    static var testCornerRadiusOverride: CGFloat?
    /// TEMP test: giấu result, chỉ test 1 component to/nhỏ + animation.
    /// Query trống = window thu về cỡ componentA, có kí tự = window nở
    /// xuống (giữ mép trên) để chứa result sau này.
    static let testExpandOnly = false
    /// Cỡ componentA lúc thu gọn: ngang = kích thước tự nhiên khai báo
    /// sẵn (baseWidth), dọc fit khít input.
    static let testCollapsedWindowSize = CGSize(width: WindowAutoScale.baseWidth, height: 68)
    /// TEMP test: chốt cứng chiều cao hàng input — chữ + icon luôn căn
    /// giữa trong 56px, padding trên/dưới đối xứng, 2 trạng thái không
    /// còn gì để xê dịch (6 + 56 + 6 = 68 = window).
    static let testBarHeight: CGFloat = 56

    /// Legibility floor for surfaces that float on the bare desktop while the
    /// material is Liquid Glass. Tune here: too low and light theme text
    /// disappears over a white window, too high and the refraction is lost.
    /// First position in the spawn cascade.
    static let searchBarRevealIndex = 0
    /// Shorter than the stored title: a banner shares its line with the undo
    /// hint, and the pill is meant to read at a glance.
    static let bannerTitleLimit = 32

    /// How many shortcuts a hint line may name. Three is what fits the narrowest
    /// card footer in one row, and is the budget linows keeps too.
    static let hintItemBudget = 3
    static let hintSeparator = "  •  "

    var runningAppsPlacement: RunningAppsPlacement {
        themeStore.settings.runningAppsPlacement
    }

    /// Not in command mode, not showing theme settings, not showing the help
    /// screen - the coarse "nothing else has taken over the launcher" gate
    /// shared by the running-apps strip, floating-card layout, home hint,
    /// empty-query rest state, and delete confirmation.
    var isLauncherIdle: Bool {
        !isCommandMode && !appUIState.showsThemeSettings && !showsHelpScreen
    }

    /// Whether the running-apps strip shows.
    /// ponytail: strip removed from launcher UI — always hidden.
    /// Service + core untouched, revert by restoring the old gate.
    var shouldShowRunningAppsStrip: Bool {
        false
    }

    /// Activates the strip icon assigned to Cmd+`key`. The key is mapped
    /// to a visual position via the ergonomic layout in
    /// `AppConstants.Launcher.RunningAppsStrip.visualPosition(forKey:total:)`.
    /// On success the launcher is *not* hidden here - instead we let
    /// `didResignActiveNotification` close it, which only fires after
    /// macOS has handed key-window status to the target app. Hiding
    /// synchronously raced that handoff and left the keyboard focused
    /// nowhere visible.
    @discardableResult
    func activateRunningApp(forKey key: Int) -> Bool {
        // ponytail: strip removed from launcher — Cmd+N switch disabled, service kept.
        return false
    }

    static let postHideActivationDelay: TimeInterval = 0.01
    @FocusState var isQueryFocused: Bool

    let bridge = EngineBridge.shared
    let shouldShowTestHint = LauncherView.cachedShouldShowTestHint

    static let cachedShouldShowTestHint: Bool = {
        let env = ProcessInfo.processInfo.environment
        if let value = env["LUMIO_DEV_HINT"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            ["1", "true", "yes", "on"].contains(value)
        {
            return true
        }

        if let configPath = env["LUMIO_CONFIG_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            configPath.lowercased().hasSuffix("config.dev")
        {
            return true
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier,
            bundleIdentifier.caseInsensitiveCompare("noah-code.Lumio") != .orderedSame
        {
            return true
        }

        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path.lowercased()
        if bundlePath.contains("/lumio dev.app") {
            return true
        }

        return false
    }()

    static let debugEventLoggingEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        let raw = env["LUMIO_UI_DEBUG_EVENTS"] ?? env["LUMIO_DEV_HINT"] ?? ""
        return ["1", "true", "yes", "on"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }()

    static let logger = Logger(subsystem: "noah-code.Lumio", category: "ui")

    func logUIEvent(_ message: String) {
        guard Self.debugEventLoggingEnabled else { return }
        Self.logger.notice("\(message, privacy: .public)")
    }

    static let clipboardSubtitleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    let commandCatalog: [AppCommand] = AppConstants.Launcher.commandCatalog

    var pinnedLookupScope: LauncherPinnedLookupScope {
        LauncherSearchLogic.pinnedLookupScope(for: query)
    }

    var normalizedPinnedLookupQuery: String? {
        LauncherSearchLogic.normalizedPinnedLookupQuery(for: query, scope: pinnedLookupScope)
    }

    var shouldInjectFinderResult: Bool {
        LauncherSearchLogic.shouldInjectFinder(
            normalizedQuery: normalizedPinnedLookupQuery,
            scope: pinnedLookupScope
        )
    }

    var quickFolderPinnedResults: [LauncherResult] {
        guard pinnedLookupScope == .unscoped || pinnedLookupScope == .folders else { return [] }
        guard let normalized = normalizedPinnedLookupQuery else { return [] }

        return AppConstants.Launcher.QuickFolder.entries.compactMap { entry in
            let normalizedTitle = entry.title.lowercased()
            let isMatch = normalizedTitle.contains(normalized)
                || (normalizedTitle.hasPrefix(normalized)
                    && normalized.count >= AppConstants.Launcher.QuickFolder.minPrefixMatchLength)
            guard isMatch else { return nil }

            let folderPath = entry.resolvedPath(homeDirectory: NSHomeDirectory())
            guard FileManager.default.fileExists(atPath: folderPath) else { return nil }

            return LauncherResult(
                id: "\(AppConstants.Launcher.QuickFolder.idPrefix)\(normalizedTitle)",
                kind: .folder,
                title: entry.title,
                subtitle: entry.subtitle ?? AppConstants.Launcher.QuickFolder.pinnedSubtitle,
                path: folderPath,
                score: AppConstants.Launcher.Finder.pinnedScore
            )
        }
    }

    var finderPinnedResult: LauncherResult {
        LauncherResult(
            id: AppConstants.Launcher.Finder.pinnedResultID,
            kind: .app,
            title: "Finder",
            subtitle: AppConstants.Launcher.Finder.pinnedSubtitle,
            path: AppConstants.Launcher.Finder.appPath,
            score: AppConstants.Launcher.Finder.pinnedScore
        )
    }

    var backendFilteredResults: [LauncherResult] {
        var sourceResults = backendResults

        for quickFolder in quickFolderPinnedResults.reversed() {
            let alreadyPresent = sourceResults.contains { item in
                item.kind == .folder && item.path == quickFolder.path
            }
            guard !alreadyPresent else { continue }

            // A same-titled app (e.g. Apple Music.app vs the ~/Music quick folder)
            // already won the backend's type-priority ranking - don't let the pin
            // bump it out of first place. Surface the folder right below it instead
            // of dropping it, so it's still reachable.
            let rivalAppIndex = sourceResults.firstIndex { item in
                item.kind == .app
                    && item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == quickFolder.title.lowercased()
            }
            sourceResults.insert(quickFolder, at: rivalAppIndex.map { $0 + 1 } ?? 0)
        }

        if shouldInjectFinderResult {
            let hasFinder = sourceResults.contains {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == AppConstants.Launcher.Finder.appName
                    || $0.path == AppConstants.Launcher.Finder.appPath
            }
            if !hasFinder {
                sourceResults.insert(finderPinnedResult, at: 0)
            }
        }

        return LauncherSearchLogic.dedupe(results: sourceResults)
    }

    var isClipboardQuery: Bool {
        LauncherClipboardFeature.isClipboardQuery(query)
    }

    var isClipboardImageQuery: Bool {
        LauncherClipboardImageFeature.isClipboardImageQuery(query)
    }

    var isRecentQuery: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix(AppConstants.Launcher.QueryPrefix.recent)
    }

    /// A leading `"` opens the prefix-discovery menu: a list of every query
    /// prefix with a short description. Typing after the `"` (e.g. `"folder`)
    /// filters the list by name/description; picking one fills the prefix in.
    var isPrefixSuggestionQuery: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix(AppConstants.Launcher.QueryPrefix.discovery)
    }

    /// The text typed after the leading `"`, used to filter the discovery menu.
    var prefixSuggestionFilter: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let discovery = AppConstants.Launcher.QueryPrefix.discovery
        guard trimmed.hasPrefix(discovery) else { return "" }
        return String(trimmed.dropFirst(discovery.count))
    }

    /// Synthetic results backing the discovery menu. Rendered through the normal
    /// results list so selection/keyboard nav work as usual; `openSelectedApp`
    /// recognises the id prefix and inserts the prefix instead of opening.
    var prefixSuggestionResults: [LauncherResult] {
        let suggestions = AppConstants.Launcher.PrefixSuggestion.menuEntries(matching: prefixSuggestionFilter)
        return suggestions.enumerated().map { index, entry in
            LauncherResult(
                id: "\(AppConstants.Launcher.PrefixSuggestion.resultIDPrefix)\(entry.prefix)",
                kind: .app,
                title: entry.displayWithArg,
                subtitle: entry.description,
                path: "",
                // Preserve list order: higher score sorts first, top entry highest.
                score: suggestions.count - index
            )
        }
    }

    /// A leading `:` opens the command-discovery menu: every command with its
    /// description. Typing after the `:` (e.g. `:process`) filters by id and
    /// description; picking one enters that command. A `:<exact-id> <args>`
    /// live-trigger (e.g. `:kill chrome`) jumps straight into the command instead
    /// (handled in `onChange(of: query)`), so it isn't a discovery query.
    var isCommandSuggestionQuery: Bool {
        guard !isCommandMode else { return false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(":") else { return false }
        if let cmd = extractInlineCommand(from: query), cmd.hasSpace { return false }
        return true
    }

    /// The text typed after the leading `:`, used to filter the command menu.
    var commandSuggestionFilter: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(":") else { return "" }
        return String(trimmed.dropFirst())
    }

    /// Synthetic results backing the command-discovery menu. Rendered through the
    /// normal results list; `openSelectedApp` recognises the id prefix and enters
    /// the command instead of opening a file.
    var commandSuggestionResults: [LauncherResult] {
        let matches = AppConstants.Launcher.commandCatalog(matching: commandSuggestionFilter)
        return matches.enumerated().map { index, command in
            LauncherResult(
                id: "\(AppConstants.Launcher.CommandSuggestion.resultIDPrefix)\(command.id)",
                kind: .app,
                title: command.title,
                subtitle: command.detail,
                path: "",
                score: matches.count - index
            )
        }
    }

    var clipboardSearchTerm: String? {
        LauncherClipboardFeature.searchTerm(from: query)
    }

    var clipboardResults: [LauncherResult] {
        guard let clipboardSearchTerm else { return [] }

        return clipboardStore.search(clipboardSearchTerm).map { entry in
            LauncherClipboardFeature.makeResult(entry: entry, dateFormatter: Self.clipboardSubtitleDateFormatter)
        }
    }

    var clipboardImageResults: [LauncherResult] {
        guard let term = LauncherClipboardImageFeature.searchTerm(from: query) else { return [] }

        return clipboardStore.searchImages(term).map { entry in
            LauncherClipboardImageFeature.makeResult(
                entry: entry, dateFormatter: Self.clipboardSubtitleDateFormatter)
        }
    }

    // URL-aware rows (urlResult, recentURLResults, mergeByScore) live in
    // LauncherView+URLResults.swift.

    var displayedResults: [LauncherResult] {
        if isPrefixSuggestionQuery { return prefixSuggestionResults }
        if isCommandSuggestionQuery { return commandSuggestionResults }
        // Before the text history: `ci"` starts with `c`, but not with `c"`.
        if isClipboardImageQuery { return clipboardImageResults }
        if isClipboardQuery { return clipboardResults }
        if isProcessQuery { return processResults }
        // Recent URLs interleave with local results by frecency.
        let ranked = mergeByScore(backendFilteredResults, recentURLResults)
        let base: [LauncherResult]
        if let urlResult {
            base = URLRowPlacement.merged(
                url: urlResult.result,
                isBareHost: urlResult.tier == .bareHost,
                into: ranked
            )
        } else {
            base = ranked
        }
        return base
    }



    var isTranslationQuery: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return extractTranslationQuery(from: trimmed) != nil
    }

    var currentHint: String {
        hintItems.prefix(Self.hintItemBudget).joined(separator: Self.hintSeparator)
    }

    /// What the footer says, wherever the footer is drawn.
    var panelHint: String {
        currentHint
    }

    /// Every hint line is at most three items, the same budget linows keeps
    /// (apps/linows/src/js/app.js). The footer sits inside a card, so a fourth
    /// item wraps or truncates; the keys left out are still listed in
    /// Settings > Shortcuts.
    var hintItems: [String] {
        if appUIState.showsThemeSettings {
            return ["Cmd+Shift+; apply config", "Cmd+Shift+, close settings", "Cmd+H help"]
        }

        if isHideAppConfirmationVisible {
            return ["Y confirm", "N cancel", "Esc back"]
        }

        if isCommandMode {
            if activeCommandID == AppConstants.Launcher.Command.kill {
                return ["Y confirm", "N cancel", "Esc back"]
            }
            if activeCommandID == AppConstants.Launcher.Command.speed {
                return ["R rerun", "E show IP", "Esc back"]
            }
            return ["Enter run", "Tab select", "Esc back"]
        }

        if extractTranslationQuery(from: query.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            return ["Live lookup", "Type to refine", "Cmd+H help"]
        }

        if showsHelpScreen {
            return ["Enter open", "Cmd+H close help", "Esc hide launcher"]
        }

        if isPrefixSuggestionQuery {
            return ["Enter pick prefix", "Up/Down move", "Esc clear"]
        }

        if isCommandSuggestionQuery {
            return ["Enter run command", "Up/Down move", "Esc clear"]
        }

        if isClipboardImageQuery {
            return ["Enter copy", "Cmd+D remove"]
        }

        if isClipboardQuery {
            return ["Enter copy clip", "Cmd+D remove clip"]
        }

        // Mirrors the linows ps" hint, with Cmd for Ctrl.
        if isProcessQuery {
            return ["Enter CPU", "Cmd+D kill", "Cmd+C copy PID"]
        }

        var hints = [enterHint]
        hints.append(AppConstants.Launcher.ActionMenu.openHint)
        hints.append("Cmd+H help")
        return hints
    }

    /// What Enter does to the selected row. A declared block performs steps or
    /// runs its own command, so claiming "open" there is simply wrong.
    private var enterHint: String {
        guard let id = selectedResultID,
              let selected = displayedResults.first(where: { $0.id == id }),
              selected.kind == .action
        else { return "Enter open" }
        return "Enter run"
    }


    var usesOwnResultPanel: Bool {
        isClipboardQuery || isClipboardImageQuery || isPrefixSuggestionQuery
            || isCommandSuggestionQuery || isTranslationQuery || isProcessQuery
    }

    var commandNamePart: String {
        guard activeCommandID == nil else { return "" }
        let normalized = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        return normalized.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
    }

    var commandArgsPart: String {
        if activeCommandID != nil {
            return commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let normalized = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let splitPoint = normalized.firstIndex(where: { $0.isWhitespace }) else { return "" }
        return String(normalized[splitPoint...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var activeCommand: AppCommand? {
        guard let activeCommandID else { return nil }
        return commandCatalog.first(where: { $0.id == activeCommandID })
    }

    var activeCommandAcceptsInput: Bool {
        guard let activeCommandID else { return false }
        if activeCommandID == AppConstants.Launcher.Command.speed { return false }
        return true
    }

    var isKillConfirmationVisible: Bool {
        isCommandMode
            && activeCommandID == AppConstants.Launcher.Command.kill
            && pendingKillCandidate != nil
    }

    var isDeleteConfirmationVisible: Bool {
        !isCommandMode && pendingEmptyTrashCount != nil
    }

    var isHideAppConfirmationVisible: Bool {
        !isCommandMode && pendingHideAppResult != nil
    }

    var liveCommandPreview: String? {
        guard isCommandMode else { return nil }
        return nil
    }

    var hasSudoWarning: Bool { false }

    var filteredCommands: [AppCommand] {
        let prefix = commandNamePart.lowercased()
        if prefix.isEmpty {
            return commandCatalog
        }
        return commandCatalog.filter { $0.id.hasPrefix(prefix) }
    }

    var killSuggestions: [KillCommand.Candidate] {
        _ = killListRefreshTick
        let searchTerm = commandArgsPart.trimmingCharacters(in: .whitespacesAndNewlines)
        return KillCommand.suggestions(searchTerm: searchTerm, processes: processModel.candidates)
            .filter { !recentlyKilledPIDs.contains($0.pid) }
    }

    var body: some View {
        // Mirrored onto the window's layers in `WindowConfigurator`.
        let windowCornerRadius = themeStore.panelRadius
        // When floating, use a single uniform gap between the top row and the
        // columns so it matches the horizontal gap between the columns (i3 style);
        // otherwise keep the classic fixed spacing.
        let contentSpacing: CGFloat = showsFloatingCards ? innerGap : (isCommandMode ? 8 : 12)
        let contentPadding: CGFloat = isCommandMode ? 10 : 14

        // Running apps render inside the search bar (see panelContent), not as a
        // floating strip that grows the window. The launcher is always a single
        // fixed-size panel regardless of the running-apps toggle.
        borderedPanel(windowCornerRadius: windowCornerRadius, contentSpacing: contentSpacing, contentPadding: contentPadding)
        // No `.rootReveal`: its opacity rasterized the panel on every show, and
        // the bar's backdrop must draw straight through. The spawnReveal
        // cascade still animates the open.
        .ignoresSafeArea()
        .onAppear {
            refreshSearchResults()
            startKeyboardNavigationIfNeeded()
            focusActiveInput()
            refreshClipboardMonitoringMode()
            reloadQueryRetentionPolicy()
            // ponytail: strip removed — skip running-apps refresh, service kept.
            // A cold `lumio <mode>`: this process launched to serve it.
            if let pending = LaunchModes.pendingQuery {
                LaunchModes.pendingQuery = nil
                applyLaunchQuery(pending)
            }
        }
        .onDisappear {
            invalidateSearchRequests()
            bannerTask?.cancel()
            lookupPreviewTask?.cancel()
            recentURLTask?.cancel()
            keyboardMonitor.stop()
            clipboardStore.setMonitoringMode(.background)
        }
        // Bumped on every show, so it stands in for the missing re-onAppear.
        .onChange(of: query) { _, _ in
            handleQueryChange()
        }
        // TEMP single-component: co/nở window theo trạng thái thu gọn.
        .onChange(of: testWantsCollapsedWindow) { _, collapsed in
            applyTestWindowSize(collapsed: collapsed, animated: true)
        }
        .onChange(of: selectedResultID) { _, _ in
            // Prefetch process detail for the newly selected process row so the
            // preview pane fills in (cheap per-selection reads, cached by pid).
            loadProcessDetailForSelection()
        }
        .onChange(of: isProcessQuery) { _, entering in
            // Enumerate the process table once on entering `ps"` mode; leaving
            // invalidates so the next entry re-enumerates fresh.
            if entering {
                processModel.loadSnapshotIfNeeded()
            } else if activeCommandID != AppConstants.Launcher.Command.kill {
                // /kill scores the same snapshot; don't drop it when the query
                // switches straight into that panel.
                processModel.invalidate()
            }
        }
        .onChange(of: processModel.candidates) { _, _ in
            repairProcessSelection()
        }
        .background(notificationHandlers)
    }

    /// TEMP single-component: true khi window cần thu về cỡ componentA
    /// (chưa gõ, màn home classic). Mọi thứ khác (command/help/settings,
    /// floating tiles) giữ window cao như cũ.
    var testWantsCollapsedWindow: Bool {        Self.testExpandOnly && isLauncherIdle && !showsFloatingCards && hidesResultsForEmptyQuery
    }

    /// Co/nở window giữ nguyên mép trên và tâm ngang — gõ chữ thì panel
    /// nở xuống dưới đúng kiểu Spotlight. Chiều cao lúc nở = cỡ panel chuẩn.
    /// Chạy qua animator easeOut ngắn để mượt, thay vì animate mặc định.
    func applyTestWindowSize(collapsed: Bool, animated: Bool) {
        let rzLog = Logger(subsystem: "noah-code.Lumio", category: "window-resize")
        rzLog.debug(
            "applyTestWindowSize collapsed=\(collapsed, privacy: .public) animated=\(animated, privacy: .public) idle=\(self.isLauncherIdle, privacy: .public) floating=\(self.showsFloatingCards, privacy: .public) empty=\(self.hidesResultsForEmptyQuery, privacy: .public)"
        )
        guard Self.testExpandOnly, !showsFloatingCards else { return }
        guard let window = launcherWindow() else { return }
        let full = window.frame
        let size = collapsed
            ? Self.testCollapsedWindowSize
            : CGSize(width: Self.testCollapsedWindowSize.width, height: WindowAutoScale.baseSize().height)
        let rect = NSRect(
            x: full.midX - size.width / 2, y: full.maxY - size.height, width: size.width, height: size.height)
        // TEMP test: đồng bộ mask của window (viên thuốc lúc thu gọn).
        Self.testCornerRadiusOverride = collapsed
            ? Self.testCollapsedWindowSize.height / 2 : themeStore.panelRadius
        rzLog.debug(
            "resize from=\(NSStringFromRect(full), privacy: .public) to=\(NSStringFromRect(rect), privacy: .public)"
        )
        guard animated else {
            window.setFrame(rect, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(rect, display: true)
        }
    }

    /// Khối dưới bar có đang nở không: command/help, hoặc home có chữ.
    /// Chỉ là nguồn lật onChange — animation chạy explicit trên Group cha
    /// (identity ổn định), không animate frame qua chỗ swap view con.
    private var belowBarSpringExpanded: Bool {
        isCommandMode || showsHelpScreen || (isLauncherIdle && !hidesResultsForEmptyQuery)
    }
    /// 0 = thu, 1 = nở. Group cha scale Y neo mép trên + fade theo mix này;
    /// mép dưới là thứ duy nhất quét lên/xuống, quá đà rồi settle.
    @State private var belowBarSpringMix: CGFloat = 0

    /// Second half of the root modifier chain (store subscriptions and
    /// notification handlers), attached to a zero-size background view so
    /// the type checker sees two short chains instead of one long one.
    private var notificationHandlers: some View {
        Color.clear
        .onReceive(clipboardStore.$entries) { _ in
            refreshClipboardSelectionIfNeeded()
        }
        .onReceive(clipboardStore.$imageEntries) { _ in
            refreshClipboardSelectionIfNeeded()
        }
        .onChange(of: commandInput) { _, _ in
            if isCommandMode {
                if commandArgsPart.isEmpty {
                    commandFeedback = ""
                }
                if activeCommandID == AppConstants.Launcher.Command.kill {
                    if selectedKillSuggestionIndex != nil || pendingKillCandidate != nil {
                        logUIEvent("kill input changed -> clear pending/select input='\(commandArgsPart)'")
                    }
                    pendingKillCandidate = nil
                    selectedKillSuggestionIndex = nil
                }
                setInitialSelection()
            }
        }
        .onChange(of: activeCommandID) { _, newID in
            if let newID { appUIState.lastCommandID = newID }
            // /kill ranks the same cached snapshot; take a fresh one on entry.
            if newID == AppConstants.Launcher.Command.kill {
                processModel.refreshSnapshot()
            }
        }
        .onChange(of: appUIState.showsThemeSettings) { _, showsSettings in
            if showsSettings {
                showsHelpScreen = false
                keyboardMonitor.stop()
                NotificationCenter.default.post(name: .lookFocusSettingsInputRequested, object: nil)
            } else {
                startKeyboardNavigationIfNeeded()
                focusActiveInput()
            }
        }
        .onMoveCommand { direction in
            moveSelection(direction)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            focusActiveInput()
            refreshClipboardMonitoringMode()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
        ) { _ in
            // Not while a TCC dialog is up: it steals focus, and hiding here
            // backgrounds the app so the next prompt never appears.
            if !PermissionPrompt.isPresenting, launcherWindow()?.isVisible == true {
                Logger(subsystem: "noah-code.Lumio", category: "window-resize")
                    .debug("didResignActiveNotification -> hideLauncherWindow(restorePreviousApp: false)")
                hideLauncherWindow(restorePreviousApp: false)
            }
            refreshClipboardMonitoringMode()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
        ) { notification in
            guard let window = notification.object as? NSWindow,
                window === launcherWindow()
            else { return }
            // The query survives hide/show: re-entering `ps"` must not keep
            // scoring pids that exited while hidden.
            if isProcessQuery {
                processModel.refreshSnapshot()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookReloadConfigRequested)) { _ in
            reloadConfig()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookRefocusInputRequested)) { _ in
            DispatchQueue.main.async {
                focusActiveInput(recoveryDelays: [0.0], activateApp: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookActivateLauncherRequested)) { _ in
            // AppDelegate posts this after ordering the window front, where
            // clearing would repaint a visible panel. The stamp goes either
            // way, or a later open would judge an old hide.
            if launcherWindow()?.isVisible == true {
                lastHiddenAt = nil
            } else {
                clearQueryIfRetentionExpired()
            }
            activateLauncherModeAndFocus()
            refreshClipboardMonitoringMode()
        }
        // `lumio <mode>` arriving while this instance is already up.
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: LaunchModes.deliveryNotification)
        ) { notification in
            guard let text = notification.object as? String else { return }
            revealLauncherWindowForLaunch()
            activateLauncherModeAndFocus()
            // After the reveal, which runs `clearQueryIfRetentionExpired` and
            // would wipe the mode.
            applyLaunchQuery(text)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookToggleSettingsRequested)) { _ in
            toggleThemeSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookHideLauncherRequested)) { _ in
            hideLauncherWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookToggleWindowRequested)) { _ in
            toggleWindowVisibility()
            refreshClipboardMonitoringMode()
        }
    }




    /// Body of `.onChange(of: query)`, extracted so the view body stays within
    /// the type checker's budget.
    private func handleQueryChange() {
            let clearedBySubmit = querySilentlyCleared
            querySilentlyCleared = false
            if clearedBySubmit {
                return
            }
            // Editing the query dismisses a pending Empty Trash confirmation,
            // mirroring how the kill command clears its pending candidate.
            if pendingEmptyTrashCount != nil {
                pendingEmptyTrashCount = nil
            }
            if pendingHideAppResult != nil {
                pendingHideAppResult = nil
            }
            if !isCommandMode, let cmd = extractInlineCommand(from: query), cmd.hasSpace {
                enterCommandMode(commandID: cmd.id, prefilledInput: cmd.args)
                return
            }
            previewLookupDefinition(for: query)
            if !isCommandMode {
                if showsHelpScreen {
                    showsHelpScreen = false
                }
                if usesOwnResultPanel {
                    setInitialSelection()
                } else {
                    refreshSearchResults()
                }
            }
            // Previously-opened URLs matching the query (url-history spec).
            refreshRecentURLs()
    }

    @ViewBuilder
    private func borderedPanel(windowCornerRadius: CGFloat, contentSpacing: CGFloat, contentPadding: CGFloat) -> some View {
        // TEMP test: lúc thu gọn bo 50% chiều cao = viên thuốc như Spotlight,
        // lúc nở về lại panelRadius. Mọi lớp (nền, clip, mask window) dùng
        // chung số này để không lớp nào lòi ra ngoài lớp nào.
        let testRadius = Self.testExpandOnly && testWantsCollapsedWindow
            ? Self.testCollapsedWindowSize.height / 2 : windowCornerRadius
        ZStack {
            WindowAppearancePin(appearance: themeStore.themeAppearance())
                .frame(width: 0, height: 0)

            // When the content floats free (floating panes, or resting on an empty
            // query) the blur + tint backdrop box is dropped so the tiles sit on
            // the bare desktop. A background image, if set, is cropped into each
            // tile (see tileBackground) rather than filling the gaps.
            // TEMP single-component: ở classic (gap 0) giữ themedBackground
            // cả lúc trống lẫn lúc nở — cùng 1 view chỉ đổi size, không swap
            // 2 nền cho nhau nữa.
            if !barFloatsFree || (Self.testExpandOnly && isLauncherIdle && !showsFloatingCards) {
                if Self.testSolidBackground && Self.testExpandOnly {
                    // Nền đỏ đặc duy nhất, co/nở theo window — không blur,
                    // không lớp phủ, morph không khựng.
                    RoundedRectangle(cornerRadius: testRadius, style: .continuous)
                        .fill(Color.red)
                } else {
                    themedBackground
                    // TEMP test: A = đỏ, hiện cả lúc trống lẫn lúc có result
                    // nên khi gõ chữ nó mở rộng xuống chứ không bị thay thế.
                    if Self.testTintBackgrounds && isLauncherIdle {
                        Color.red.opacity(0.45)
                    }
                }
            }

            VStack(alignment: .leading, spacing: contentSpacing) {
                panelContent
            }
            // Tighter top inset so the search bar sits closer to the window's
            // top edge; keep the original padding on the other three sides.
            // TEMP test: bottom = top để A fit đối xứng quanh input.
            .padding(.top, max(4, contentPadding - 8))
            .padding(.horizontal, contentPadding)
            .padding(.bottom, Self.testExpandOnly ? max(4, contentPadding - 8) : contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .font(themeStore.uiFont())
            .foregroundStyle(themeStore.fontColor())
            // No wash on top of the backdrop: the panel is one continuous
            // Liquid Glass sheet, and any flat fill over it sheets the droplet
            // into a separate "card" floating over the desktop. The glass
            // (or the fallback blur + tint) already carries the depth.
            .contentShape(Rectangle())
            .onTapGesture { focusActiveInput() }
        }
        .coordinateSpace(name: Self.panelCoordinateSpace)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { panelSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in panelSize = newSize }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: testRadius, style: .continuous))
        .overlay { borderOverlay(cornerRadius: testRadius) }
        .modifier(PanelDecorationsModifier(
            testHint: { testHintOverlay },
            copyright: { copyrightOverlay },
            killBar: { killConfirmationOverlay },
            deleteBar: { deleteConfirmationOverlay },
            hideAppBar: { hideAppConfirmationOverlay }
        ))
        .layoutPriority(1)
    }

    private func searchInputBar(showsBackground: Bool = true) -> some View {
        SearchInputBar(
            text: $query,
            isCommandMode: $isCommandMode,
            isQueryFocused: $isQueryFocused,
            activeCommand: activeCommand,
            themeStore: themeStore,
            showsBackground: showsBackground,
            revealToken: appearanceRevealToken,
            onSubmit: handleSubmit,
            onExitCommandMode: exitCommandMode
        )
    }

    @ViewBuilder
    private var panelContent: some View {
        if appUIState.showsThemeSettings {
            ThemeSettingsView(settings: $themeStore.settings)
        } else {
            if !isCommandMode && !showsHelpScreen {
                // ponytail: running-apps strip removed — search bar takes full width.
                topRowBar {
                    HStack(alignment: .center, spacing: 10) {
                        searchInputBar(showsBackground: false)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: Self.testExpandOnly ? Self.testBarHeight : nil)
                }
            }

            // Spotlight's hairline between the search field and the results.
            // TEMP test: ẩn để morph chỉ còn bar + nền, không relayout giữa chừng.
            if isLauncherIdle && !hidesResultsForEmptyQuery && !Self.testExpandOnly {
                Rectangle()
                    .fill(themeStore.dividerColor())
                    .frame(height: 0.5)
                    .padding(.horizontal, 4)
                    .padding(.vertical, -4)
                    .opacity(belowBarSpringMix)
            }

            if let bannerMessage {
                bannerView(message: bannerMessage)
            }

            // Mép dưới nảy lò xo: cả khối dưới bar (command/help/result) nở
            // từ trên xuống, thu lại thì ngược lại — bar đứng yên, chỉ mép
            // dưới chuyển động. Animation đặt trên Group cha (scale Y neo
            // mép trên + fade), vì Group không bao giờ đổi identity kể cả
            // khi view con bên trong swap (Spacer ↔ result).
            Group {
            if Self.testExpandOnly && isLauncherIdle {
                // Chưa hiện result: window tự co/nở nên Spacer lấp đầy
                // phần còn lại là đủ, không cần khối giữ chỗ.
                Spacer(minLength: 0)
            } else if isCommandMode {
                commandModeView
            } else if showsHelpScreen {
                LauncherHelpScreenView(
                    themeStore: themeStore,
                    initialTopic: .all)
            } else if isTranslationQuery {
                floatingPanel {
                    LookupDefinitionPanelView(
                        definition: lookupDefinition,
                        themeStore: themeStore
                    )
                }
            } else if (isClipboardQuery || isClipboardImageQuery) && displayedResults.isEmpty {
                // The empty clipboard screen is naturally two columns (history /
                // how-to), so float it as the same two-card grid as the results.
                let copy: ClipboardEmptyStateCopy = isClipboardImageQuery ? .images : .text
                if showsFloatingCards {
                    twoPaneGrid(hasRight: true) {
                        ClipboardEmptyInfoView(themeStore: themeStore, copy: copy)
                    } right: {
                        ClipboardEmptyHelpView(themeStore: themeStore, copy: copy)
                    }
                } else {
                    ClipboardEmptyStateView(themeStore: themeStore, copy: copy)
                }
            } else if isRecentQuery && displayedResults.isEmpty {
                floatingPanel { RecentEmptyStateView(themeStore: themeStore) }
            } else if hidesResultsForEmptyQuery {
                Spacer(minLength: 0)
            } else {
                resultsRow
            }
            }
            // KHÔNG bao giờ scale về đúng 0: AppKit abort (SIGABRT trong
            // convertSizeFromBacking) khi ScrollView kết quả mount/unmount
            // dưới transform suy biến — 2 crash 13:59 + 14:08 đều từ đây.
            // 0.01 + opacity 0 + clipped = vô hình mà transform vẫn khả nghịch.
            .scaleEffect(x: 1, y: max(belowBarSpringMix, 0.01), anchor: .top)
            .opacity(belowBarSpringMix)
            .clipped()
            .accessibilityHidden(!belowBarSpringExpanded)
            .onAppear { belowBarSpringMix = belowBarSpringExpanded ? 1 : 0 }
            .onChange(of: belowBarSpringExpanded) { _, expanded in
                // Expand ~1s (response 0.55): mép dưới quét xuống, quá đà
                // rung vài nhịp rồi settle. Collapse chạy ngược lại.
                withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) {
                    belowBarSpringMix = expanded ? 1 : 0
                }
            }

            if isCommandMode {
                Spacer(minLength: 0)
            }

            // While floating, every card carries its own hint footer; only the
            // classic (no-gap) layout keeps the full-width bar below the panel.
            // TEMP test: ẩn để morph không relayout giữa chừng.
            if !showsFloatingCards
                && !hidesResultsForEmptyQuery
                && !Self.testExpandOnly
                && !isKillConfirmationVisible
                && !isDeleteConfirmationVisible
                && !isHideAppConfirmationVisible
            {
                HintBar(hint: panelHint, themeStore: themeStore)
                    .opacity(belowBarSpringMix)
            }
        }
    }

    @ViewBuilder
    private func bannerView(message: String) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 1), weight: .semibold))
                .foregroundStyle(themeStore.fontColor())
                // A banner is one line inside a capsule. Anything longer is
                // truncated by its caller; without this a stray newline in an
                // interpolated title stacks the pill into a tall narrow block.
                .lineLimit(1)
                .truncationMode(.middle)
            if let copyText = bannerCopyText {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                    showBanner("Copied", style: .info, duration: 1.0)
                }
                .buttonStyle(.plain)
                .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(themeStore.surfaceFill(), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(bannerStyle.background, in: Capsule())
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var resultsRow: some View {
        resultsContent
            // TEMP test: B (result) = xanh, nằm BÊN TRONG panel đỏ (A mở rộng).
            .background {
                if Self.testTintBackgrounds && isLauncherIdle {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.blue.opacity(0.45))
                }
            }
    }













    /// Only ever the input: it waits for an Enter a person has to press.
    ///
    /// Whatever the launcher was showing has to be left first. A warm
    /// `lumio clipboard` can land while command mode, help or
    /// settings owns the panel, and each of those would swallow the prefix:
    /// command mode types into `commandInput`, and
    /// `focusActiveInput` routes to the settings field.
    private func applyLaunchQuery(_ text: String) {
        exitCommandMode()
        showsHelpScreen = false
        appUIState.showsThemeSettings = false
        query = text
        focusActiveInput()
    }

















    @ViewBuilder
    private var resultsContent: some View {
        resultsListAndPreview
    }





    @ViewBuilder
    private var resultsListAndPreview: some View {
        twoPaneGrid(hasRight: hasRightPane) {
            ResultsListView(
                results: displayedResults,
                selectedID: selectedResultID,
                pickedKeys: Set(pickedKeys),
                themeStore: themeStore,
                onSelect: { selectedResultID = $0 },
                onOpen: { _ in openSelectedApp() }
            )
        } right: {
            if !pickedKeys.isEmpty {
                PickedItemsPanel(
                    pickedKeys: pickedKeys,
                    pickedByKey: pickedResultsByKey,
                    themeStore: themeStore,
                    onRemove: { removePicked(key: $0) },
                    onClearAll: { clearAllPicked() },
                    onOpenAll: { openAllPicked() }
                )
            } else if let selectedResult = previewResult {
                ResultPreviewView(
                    result: selectedResult,
                    onDeleteClipboard: selectedResult.kind == .clipboard
                        ? { deleteClipboardResult(resultID: selectedResult.id) }
                        : nil,
                    processDetail: processDetail(for: selectedResult),
                    processCPU: processCPU(for: selectedResult),
                    isMeasuringProcessCPU: isMeasuringCPU(for: selectedResult),
                    isActionMenuOpen: isActionMenuOpen,
                    actionMenuIndex: actionMenuIndex,
                    actionMenuDescriptors: actionMenuRows,
                    onActivateActionMenuRow: { activateActionMenuRow($0) }
                )
                // Arrow-key nav assigns `selectedResultID` inside a global
                // `withAnimation` so the pill can glide (see LauncherView+
                // Selection). The preview swaps its whole contents on that same
                // change and would inherit the transaction, animating icon and
                // text on every keypress. Opted out for that value only, so the
                // pill stays the one thing moving.
                .animation(nil, value: selectedResult.id)
            }
        }
    }

    /// The two-pane home grid shared by the results screen and the clipboard
    /// empty state: a left pane and an optional right pane, one continuous
    /// glass surface (no dividing line — that seam is what cuts the droplet
    /// in two). Separated by the inner gap only when floating. On the floating
    /// grid the hint bar lives in the left card and the copyright in the right.
    @ViewBuilder
    private func twoPaneGrid<L: View, R: View>(
        hasRight: Bool,
        @ViewBuilder left: () -> L,
        @ViewBuilder right: () -> R
    ) -> some View {
        HStack(spacing: showsFloatingCards ? innerGap : 0) {
            paneCard(padding: showsFloatingCards ? 6 : 0) {
                leftPaneCardBody(hasRight: hasRight) { left() }
            }

            if hasRight {
                paneCard(padding: showsFloatingCards ? 6 : 0) {
                    rightPaneCardBody { right() }
                }
            }
        }
    }

    /// Left card contents plus, when floating, the hint footer (with the
    /// copyright appended if there is no right card to hold it).
    @ViewBuilder
    private func leftPaneCardBody<Content: View>(hasRight: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        if showsFloatingCards {
            VStack(alignment: .leading, spacing: 0) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                cardFooter {
                    HintBar(hint: currentHint, themeStore: themeStore)
                    Spacer(minLength: 8)
                    // No right card → copyright has nowhere else to go.
                    if !hasRight { copyrightLink }
                }
            }
        } else {
            content()
        }
    }

    /// Right card contents plus, when floating, the copyright footer.
    @ViewBuilder
    private func rightPaneCardBody<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if showsFloatingCards {
            VStack(alignment: .leading, spacing: 0) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                cardFooter {
                    Spacer(minLength: 0)
                    copyrightLink
                }
            }
        } else {
            content()
        }
    }

    /// Where a card footer sits, which is what decides its insets: a grid pane
    /// stops its content right above the footer, while a single panel already
    /// pads its own edges and the footer only has to match them.
    private enum CardFooterPlacement {
        case gridPane
        case singlePanel

        var horizontal: CGFloat {
            switch self {
            case .gridPane: return 6
            case .singlePanel: return 12
            }
        }

        var top: CGFloat {
            switch self {
            case .gridPane: return 6
            case .singlePanel: return 0
            }
        }

        var bottom: CGFloat {
            switch self {
            case .gridPane: return 2
            case .singlePanel: return 8
            }
        }
    }

    /// A thin footer strip inside a floating card holding a slice of the old
    /// full-width hint bar.
    @ViewBuilder
    private func cardFooter<Content: View>(
        placement: CardFooterPlacement = .gridPane,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, placement.horizontal)
        .padding(.top, placement.top)
        .padding(.bottom, placement.bottom)
    }

    /// i3-style inner gap between the three home panes (0 = classic flat layout).
    private var innerGap: CGFloat { CGFloat(themeStore.settings.innerGap) }
    private var usesPanes: Bool { innerGap > 0 }

    /// True when the carded results screen is showing with the gap on: the panes
    /// become self-contained frosted tiles floating on the bare desktop, so the
    /// window backdrop and the full-width hint/copyright strip are dropped. Other
    /// screens (command mode, settings, help, empty states) keep the backdrop.
    /// Gate for the floating layout. Kept intentionally CHEAP and STABLE: it
    /// depends only on the coarse mode (gap on, not command/settings/help/AI),
    /// never on the query text or the live result count. That stability matters -
    /// this decides whether the expensive window + per-card blur views exist, so
    /// letting it flip per keystroke (e.g. as clipboard/translation results stream
    /// in) churned NSVisualEffectViews on the main thread and froze typing.
    private var showsFloatingCards: Bool {
        usesPanes && isLauncherIdle
    }

    private var isQueryEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// With an empty query on the home screen, rest as just the search bar - hide
    /// the results columns and the hint bar below it. Applies in both modes (gap
    /// or no gap), so an empty launcher is always just the top bar.
    var hidesResultsForEmptyQuery: Bool {
        isQueryEmpty && isLauncherIdle
    }

    /// True whenever the panel has no backdrop box and its content floats freely
    /// on the desktop: either the panes are floating, or we're resting on an empty
    /// query. In both cases the top bar becomes a self-contained frosted tile so
    /// it stays legible on the bare desktop.
    private var barFloatsFree: Bool {
        showsFloatingCards || hidesResultsForEmptyQuery
    }

    /// Wraps a home-screen pane in its own rounded, frosted card so the inner gap
    /// reads as real separation between "windows". A no-op when the gap is 0,
    /// preserving the classic flat layout exactly. Each card carries its own blur
    /// so it stays legible even once the window backdrop is removed.
    @ViewBuilder
    private func paneCard(padding: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
        if barFloatsFree {
            content()
                .padding(padding)
                .background {
                    tileBackground(
                        cornerRadius: themeStore.tileRadius,
                        floats: true
                    )
                }
                .overlay {
                    tileBorder(cornerRadius: themeStore.tileRadius)
                }
                // TEMP test: tile result lúc nổi = xanh (ảnh 2).
                .overlay {
                    if Self.testTintBackgrounds {
                        Color.blue.opacity(0.45)
                            .clipShape(RoundedRectangle(cornerRadius: themeStore.tileRadius, style: .continuous))
                            .allowsHitTesting(false)
                    }
                }
                // Lift each pane off the backdrop so the three parts read as
                // separate floating tiles rather than sections of one box.
                .shadow(color: .black.opacity(0.25), radius: 7, x: 0, y: 3)
        } else {
            content()
        }
    }

    /// The frosted surface shared by every floating tile (top bar + columns). When
    /// a background image is set, each tile shows its own aligned slice of that
    /// image (cropped to the tile's window position) instead of a blurred desktop,
    /// so the tiles read as separate windows onto one image. Otherwise it takes the
    /// themed backdrop, at the same blur and tint opacities as the window.
    /// Deliberately ONE stack for the bar and the panes: an extra plate on the
    /// bar alone tinted it apart from the results below (Spotlight is a single
    /// continuous surface, so the input must grow into the suggestions, never
    /// swap fills under them).
    @ViewBuilder
    private func tileBackground(
        cornerRadius: CGFloat, floats: Bool
    ) -> some View {
        if floats, let image = themeStore.backgroundImage {
            ZStack {
                croppedBackgroundImage(image)
                // Only the opaque image needs a scrim; the blur path is
                // covered by the tint.
                themeStore.scrimColor(opacity: Self.floatingTileScrimOpacity)
                themeStore.controlFillColor()
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            // Window-server composited. The bar hosts an
            // `NSViewRepresentable`, and a `.withinWindow` material beside
            // one flips brightness whenever the layer is re-composited.
            frostedTile(
                themeStore: themeStore,
                cornerRadius: cornerRadius,
                // Seated is the only case with a window backdrop behind it.
                blendingMode: floats ? .behindWindow : .withinWindow
            )
        }
    }

    /// The outline for a floating tile, drawn with the user's configured theme
    /// border (color + thickness from Settings). Nothing is drawn when the border
    /// thickness is 0, matching the rest of the app.
    @ViewBuilder
    private func tileBorder(cornerRadius: CGFloat) -> some View {
        let width = themeStore.borderLineWidth()
        if width > 0 {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(themeStore.borderColor(), lineWidth: width)
        }
    }

    /// The slice of the full-panel background image that sits behind this tile:
    /// the image is sized to the whole panel and offset by the tile's origin in
    /// the panel coordinate space, so adjacent tiles show a continuous image cut
    /// apart by the gaps.
    @ViewBuilder
    private func croppedBackgroundImage(_ image: NSImage) -> some View {
        GeometryReader { tileGeo in
            let frame = tileGeo.frame(in: .named(Self.panelCoordinateSpace))
            backgroundImageView(image: image)
                .frame(width: panelSize.width, height: panelSize.height)
                .offset(x: -frame.minX, y: -frame.minY)
                .blur(radius: themeStore.settings.backgroundImageBlur)
        }
    }

    /// Background wrapper for the unified top row (search + running apps).
    /// Spotlight is one continuous sheet: the resting bar is the panel's own
    /// top slice — same width, same top corner radius — and typing only grows
    /// it downward. So the classic resting capsule is painted full-bleed to the
    /// window edges at `panelRadius` (bleeding past the content padding with
    /// negative insets, layout untouched: text, loupe and strip stay pixel put
    /// and the field keeps focus). Floating tiles (gap on) reuse the panes'
    /// exact tile instead.
    private func topRowBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        // Apply the chrome as a STABLE modifier chain (background/overlay/shadow
        // always present, only their values change) - never an if/else that swaps
        // the subtree - so the search field keeps its identity and its keyboard
        // focus when the bar flips between the capsule and the bare panel
        // (e.g. typing the first character out of the empty-rest state at gap 0).
        let floats = barFloatsFree
        // Classic resting: full-bleed slice of the panel itself, so width and
        // top corners coincide with the results panel exactly. Floating keeps
        // the capsule look (a tile on the desktop, not a panel top).
        let isRestingSlice = hidesResultsForEmptyQuery && !showsFloatingCards
        let barRadius = floats
            ? (hidesResultsForEmptyQuery
                ? (showsFloatingCards ? max(themeStore.tileRadius, 28) : themeStore.panelRadius)
                : themeStore.tileRadius)
            : themeStore.barRadius
        return content()
            // Wraps the content, not the chrome: the reveal leaves an opacity
            // in the tree, which would rasterize the backdrop below.
            .spawnReveal(index: Self.searchBarRevealIndex, token: appearanceRevealToken, scales: false)
            .background {
                if showsFloatingCards {
                    tileBackground(cornerRadius: barRadius, floats: true)
                } else {
                    ZStack {
                        ThemedBackdrop(
                            themeStore: themeStore,
                            blendingMode: .behindWindow,
                            cornerRadius: barRadius
                        )
                        if hidesResultsForEmptyQuery, let image = themeStore.backgroundImage {
                            croppedBackgroundImage(image)
                                .blur(radius: themeStore.settings.backgroundImageBlur)
                                .opacity(themeStore.settings.backgroundImageOpacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: barRadius, style: .continuous))
                    // Full-bleed past the VStack's content padding (see
                    // borderedPanel): the painted capsule reaches the window
                    // edges while the layout — and the text field inside it —
                    // does not move at all.
                    .padding(.horizontal, isRestingSlice ? -Self.restingBleedHorizontal : 0)
                    .padding(.top, isRestingSlice ? -Self.restingBleedTop : 0)
                    // Seated the bar sits bare on the panel: any fill of its own
                    // draws the inner "wrapper" edge around the input. Opacity, not
                    // a branch, so the chain above stays stable and focus survives
                    // the empty <-> results flip.
                    // TEMP single-component: test mode classic thì bar luôn
                    // trong suốt, panel bg phía sau là nền duy nhất.
                    .opacity(hidesResultsForEmptyQuery && !Self.testExpandOnly ? 1 : 0)
                }
            }
            .overlay {
                // TEMP test: bỏ ring của bar để input trần trên nền A.
                if floats && !Self.testExpandOnly {
                    tileBorder(cornerRadius: barRadius)
                        // The ring rides the painted capsule, so it bleeds with it.
                        .padding(.horizontal, isRestingSlice ? -Self.restingBleedHorizontal : 0)
                        .padding(.top, isRestingSlice ? -Self.restingBleedTop : 0)
                }
            }
            .shadow(color: floats ? .black.opacity(0.25) : .clear,
                    radius: floats ? 7 : 0, x: 0, y: floats ? 3 : 0)
            // TEMP test: bỏ overlay đỏ ở bar vì panel đã phủ đỏ toàn bộ —
            // giữ lại sẽ thành 2 lớp chồng nhau, vùng bar đỏ rực bất thường.
    }

    /// Wraps a single-panel home state (translation, recent empty) in
    /// a frosted floating card when floating, so it keeps a background once the
    /// window backdrop is removed. The card carries the hint and copyright footer
    /// itself, like the two-card grid does, so nothing is left stranded on the
    /// desktop below it. A no-op otherwise.
    @ViewBuilder
    private func floatingPanel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if showsFloatingCards {
            paneCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    cardFooter(placement: .singlePanel) {
                        HintBar(hint: panelHint, themeStore: themeStore)
                        Spacer(minLength: 8)
                        copyrightLink
                    }
                }
            }
        } else {
            content()
        }
    }

    /// The selected result eligible for the right-hand preview pane, or nil when
    /// the list should span full width (suggestions, nothing selected, etc.).
    private var previewResult: LauncherResult? {
        guard pickedKeys.isEmpty,
              !isPrefixSuggestionQuery, !isCommandSuggestionQuery,
              let selectedID = selectedResultID,
              let selectedResult = displayedResults.first(where: { $0.id == selectedID }),
              AppConstants.Launcher.WebURL.url(fromResultID: selectedResult.id) == nil
        else { return nil }
        return selectedResult
    }

    /// Whether a right-hand pane (picked list or preview) is currently shown.
    private var hasRightPane: Bool { !pickedKeys.isEmpty || previewResult != nil }

    private var copyrightLink: some View {
        Link("© 2026 by cavaldos", destination: URL(string: "https://github.com/cavaldos/Lumio")!)
            .font(themeStore.uiFont(size: CGFloat(max(9, themeStore.settings.fontSize - 4)), weight: .regular))
            .foregroundStyle(themeStore.fontColor(opacityMultiplier: 0.50))
    }

    @ViewBuilder
    private func borderOverlay(cornerRadius: CGFloat) -> some View {
        // The panel is one continuous glass sheet and the glass draws its own
        // specular edge. A flat stroke on top of it reads as a separate layer
        // shrink-wrapping the droplet from the outside, so it is dropped —
        // except to surface the sudo warning, which must be unmissable.
        if hasSudoWarning && themeStore.borderLineWidth() > 0 {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    Color.orange.opacity(0.95),
                    lineWidth: themeStore.borderLineWidth()
                )
        }
    }

    @ViewBuilder
    private var testHintOverlay: some View {
        if shouldShowTestHint {
            Text("TEST APP")
                .font(themeStore.uiFont(size: CGFloat(max(10, themeStore.settings.fontSize - 3)), weight: .bold))
                .foregroundStyle(Color.red.opacity(0.95))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.35), in: Capsule())
                .padding(.top, 8)
                .padding(.trailing, 10)
        }
    }

    @ViewBuilder
    private var copyrightOverlay: some View {
        // While floating the copyright moves into a card footer; on the empty-rest
        // screen it's hidden entirely; otherwise it stays in the panel's
        // bottom-right corner.
        // TEMP test: ẩn để morph không relayout giữa chừng.
        if !showsFloatingCards && !hidesResultsForEmptyQuery && !isHideAppConfirmationVisible && !Self.testExpandOnly {
            copyrightLink
                .padding(.trailing, 10)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var killConfirmationOverlay: some View {
        if isCommandMode,
           activeCommandID == AppConstants.Launcher.Command.kill,
           let pendingKillCandidate
        {
            KillConfirmationBar(
                candidate: pendingKillCandidate,
                themeStore: themeStore,
                onConfirm: {
                    runKillCommand(candidate: pendingKillCandidate)
                    self.pendingKillCandidate = nil
                },
                onCancel: {
                    self.pendingKillCandidate = nil
                }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var deleteConfirmationOverlay: some View {
        if !isCommandMode, let pendingEmptyTrashCount {
            EmptyTrashConfirmationBar(
                itemCount: pendingEmptyTrashCount,
                themeStore: themeStore,
                onConfirm: { confirmDeleteSelection() },
                onCancel: { cancelDeleteSelection() }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var hideAppConfirmationOverlay: some View {
        if !isCommandMode, let pendingHideAppResult {
            ConfirmActionBar(
                icon: NSWorkspace.shared.icon(forFile: pendingHideAppResult.path),
                title: "Hide \(pendingHideAppResult.title)?",
                detail: "Add it to app_exclude_names in .lumio/config.",
                themeStore: themeStore,
                onConfirm: { confirmHideSelectedApp() },
                onCancel: { cancelHideSelectedApp() }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
    }


}

private struct PanelDecorationsModifier<TestHint: View, Copyright: View, KillBar: View, DeleteBar: View, HideAppBar: View>: ViewModifier {
    @ViewBuilder let testHint: () -> TestHint
    @ViewBuilder let copyright: () -> Copyright
    @ViewBuilder let killBar: () -> KillBar
    @ViewBuilder let deleteBar: () -> DeleteBar
    @ViewBuilder let hideAppBar: () -> HideAppBar

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing, content: testHint)
            .overlay(alignment: .bottomTrailing, content: copyright)
            .overlay(alignment: .bottom, content: killBar)
            .overlay(alignment: .bottom, content: deleteBar)
            .overlay(alignment: .bottom, content: hideAppBar)
    }
}
