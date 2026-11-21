import AppKit
import Quartz
import SwiftUI

// macOS 26-style Spotlight launcher: Liquid Glass + animation.
//
// TIMING (every value lives in SpotlightMotion):
// 1. Open   — the glass cluster pops from 0.92 to 1, bounces gently, fades in.
// 2. Idle   — empty field for ~1.2s: the bar shrinks from the RIGHT (left edge stays put), 4 round buttons
//             split off the bar like glass droplets (glassEffectID within one group).
// 3. Type   — the round buttons merge back into the bar, the bar grows; the panel expands down to reveal
//             results, rows rise one by one (only on the first expand).
// 4. Close  — fade + slight shrink, then orderOut. Enter opens an item: slight zoom + dissolve.
//
// The window does not change size while animating (see SpotlightWindowSizing). The data
// is still the fake data in SpotlightLauncherModels — this is just the UI part.

struct SpotlightQuickItem: Identifiable {
    let kind: SpotlightKind
    let icon: String
    let label: String
    var id: SpotlightKind { kind }
}

struct SpotlightLauncherView: View {
    private typealias Metric = SpotlightSpec.Metric

    /// The idle bar's round buttons, as picked in Settings → Tabs (`quick_bubbles`).
    static var quickItems: [SpotlightQuickItem] {
        QuickBubbles.normalized(ThemeStore.shared.settings.quickBubbles)
            .compactMap(SpotlightKind.init(rawValue:))
            .map { SpotlightQuickItem(kind: $0, icon: $0.quickIcon, label: $0.quickLabel) }
    }

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themeStore = ThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassSpace
    /// Selection bar that slides between rows (matchedGeometryEffect).
    @Namespace private var selectionSpace

    // Search
    @State private var query = ""
    /// The text the rows on screen were found for (set with them in `publish`).
    @State private var shownQuery = ""
    /// Results currently shown. When the panel collapses, keep the old list so it fades
    /// out with the panel instead of vanishing first.
    /// `all` + `filter` and what the body derives from them, computed once per change
    /// instead of on every read (`results` alone is read ~40 times per render).
    @State private var list = SpotlightResultList()
    private var all: [SpotlightItem] {
        get { list.all }
        nonmutating set { list.all = newValue }
    }
    /// The sorted list for the sort menu, kept until the rows or the mode change.
    @State private var sortMemo = SortedResultsMemo()
    @State private var sel = 0
    /// Set by ⌘D on a clip: the next publish keeps this row index (the rows below slide up) instead of jumping to the top.
    @State private var keepSelOnPublish: Int?
    private var filter: SpotlightKind? {
        get { list.filter }
        nonmutating set { list.filter = newValue }
    }
    /// Item whose actions are being viewed (⌘K).
    @State private var scope: SpotlightItem?
    /// Query before opening actions — restored on exit.
    @State private var scopeReturnQuery = ""
    /// Text left in the field when the launcher was dismissed; restored on the next open.
    @State private var keptQuery = ""
    /// Tab (Dictionary, Translate, …) open when the launcher was dismissed; reopened with `keptQuery`.
    @State private var keptBrowse: SpotlightKind?
    /// Tag chips on the field when the launcher was dismissed; restored with `keptQuery`.
    @State private var keptTags: [SearchTag] = []
    /// A search was just brought back: select its text once the field has it, so typing replaces it.
    @State private var restoredQuery: String?
    /// How the list is ordered (footer button / ⌥S). Back to Default on every fresh open.
    @State private var sortMode: ResultSort = .relevance
    /// The tag browser (⌥T) runs as a command: a chip, a filter field and a list.
    private static let tagsCommand = "tags"
    private static let windowsBlockedRow = "windows|blocked"
    @State private var browse: SpotlightKind?
    /// Active search tag (`yt` + Tab → "YouTube" chip): the text is searched on that site.
    @State private var tagStack: [SearchTag] = []
    /// The stack as one tag: `downloads` ⇥ `pdf` ⇥ → PDFs in Downloads. nil = no tag.
    private var tag: SearchTag? {
        tagStack.dropFirst().reduce(tagStack.first) { merged, next in merged?.stacked(with: next) ?? merged }
    }
    /// Empty-field suggestions (recent apps / files) are on screen.
    @State private var showingSuggestions = false
    /// `suggestions_on_open` in the config, read on each open.
    @State private var suggestionsEnabled = false
    /// Pinned results: listed first when the search field is empty.
    @ObservedObject private var pins = PinStore.shared
    /// Right pane for a file: false = details card (Fluent's default), true = the preview. ⌥P.
    @AppStorage("lumio.preview.files") private var previewFiles = false
    /// Right pane for a folder: true = its newest files, false = details card. ⌥P.
    @AppStorage("lumio.preview.folders") private var previewFolders = true
    /// Bundle paths of the apps running when the launcher opened (a dot marks their rows).
    @State private var runningApps: Set<String> = []
    /// `web_suggestions` in the config (tags / always / off), read on each open.
    @State private var webSuggestMode = WebSuggestions.Mode.tags
    @State private var scrollTarget: String?
    @State private var scrollWraps = false
    /// The core search in flight (nil = results already match the input).
    @State private var searchTask: Task<Void, Never>?
    /// Whole-Mac file matches (Spotlight), added after the first results are on screen.
    @State private var fileTask: Task<Void, Never>?
    /// OCR tab while the index is still being built: searches again shortly, so new matches
    /// and the progress line show up without typing.
    @State private var ocrPollTask: Task<Void, Never>?
    /// Enter pressed before results for the latest text arrived: open as soon as they do.
    @State private var activateWhenReady = false

    // Presentation
    /// Launcher is open (or opening). Set synchronously, not animated.
    @State private var isOpen = false
    @State private var dismissing = false
    @State private var shownScale = false
    @State private var shownAlpha = false
    @State private var launching = false
    @State private var expanded = false
    @State private var idle = false
    /// Round button Tab has moved to while idle (Enter opens it). nil = the field.
    @State private var quickFocus: Int?
    @State private var panelHeight = SpotlightSpec.Metric.barHeight
    /// Delay for the next height animation (see SpotlightMotion.expandAfterMerge).
    @State private var resizeDelay: Double = 0
    /// When the 4 round buttons started merging back into the bar.
    @State private var mergeStartedAt = Date.distantPast
    @State private var introUntil = Date.distantPast
    @State private var toastMsg: String?
    @State private var mouseGate = MouseGate()
    /// Clipboard: the side preview (full text + details) is open. It opens after resting on a row
    /// for `clipPreviewDelay`, then follows the selection until the tab is left.
    @State private var clipPreviewShown = false
    @State private var clipPreviewTask: Task<Void, Never>?
    /// Row under the mouse pointer, so leaving it cancels the pending clipboard preview.
    @State private var hoveredRow: Int?
    /// Bumped when a PreviewFacts lookup lands, so the chips are built again with it.
    @State private var previewFactsTick = 0

    // Legacy launcher modes (prefix / command) — reusing the legacy modules as-is.
    /// Clipboard watcher (c" / ci"). Must live with the launcher: the legacy launcher isn't
    /// built in Spotlight mode, so nobody else records history.
    @StateObject private var clipboardStore = ClipboardHistoryStore()
    @StateObject private var processModel = ProcessFinderModel()
    /// Command currently open (`:kill`, `:emptytrash`, `:help`). nil = normal search.
    @State private var activeCommand: String?
    /// ⌘/ reopens the most recently used command, like the legacy launcher.
    @State private var lastCommand = SpotlightCommands.kill
    /// :kill — the first Enter only "arms" this process; the second Enter kills it.
    @State private var armedKillPID: Int32?
    /// Destructive actions (Move to Trash, Empty Trash, Hide from Results) need a second Enter:
    /// the key of the armed one.
    @State private var armedConfirm: String?
    /// :emptytrash — item count read when the command opens.
    @State private var trashCount: Int?
    /// Clear the kept search when hidden longer than `query_retention_seconds`.
    @State private var hiddenAt: Date?
    @State private var retentionSeconds = AppConstants.Launcher.QueryRetention.defaultSeconds
    /// tr" — translations of the typed text (the rows only name the target languages).
    @State private var translation = SpotlightTranslationBatch()
    @State private var keyMonitor = SpotlightKeyMonitor()

    @State private var idleTask: Task<Void, Never>?
    @State private var dismissTask: Task<Void, Never>?
    @State private var hiddenTrim = DelayedAction()
    /// The pending selected-text read of the last open (Accessibility IPC runs off-main).
    @State private var selectionTask: Task<Void, Never>?
    @State private var toastTask: Task<Void, Never>?
    @State private var pidToRestore: pid_t?
    @FocusState private var isFocused: Bool

    // MARK: - Derived

    private var results: [SpotlightItem] {
        guard sortMode != .relevance, scope == nil, activeCommand == nil, !inModeTab else { return list.results }
        return sortMemo.sorted(list, by: sortMode)
    }

    /// Pills for the groups present in the results (see `SpotlightResultList.kinds`).
    private var kinds: [SpotlightKind] { list.kinds }

    private var inOCR: Bool { browse == .content }

    /// On OCR or a tool tab: a different search, not a filter of the name results.
    private var inModeTab: Bool { browse.map(SpotlightKind.modeTabs.contains) ?? false }

    private var panelWidth: CGFloat { idle ? Metric.idleWidth : Metric.panelWidth }

    /// The panel always leaves room for at least `minRowsWithPreview` rows when open: the right half is the
    /// preview, which needs room for code / images even with just one or two results.
    /// tw" shows dictionary entries, which need the full height whatever the number of words.
    private var rowSlots: Int {
        isLookup || isClipboard ? Metric.maxVisibleRows : max(results.count, Metric.minRowsWithPreview)
    }

    /// Clipboard tab: one full-width list of one-line clips, no preview, like Maccy.
    private var isClipboard: Bool { browse == .clip && scope == nil && activeCommand == nil }

    /// Clipboard: the list fills the panel until the side preview opens.
    private var showsPreview: Bool { !isClipboard || clipPreviewShown }

    private static let clipPreviewDelay: Duration = .seconds(1)

    /// tw": the list is a narrow column of words, like the Dictionary.app sidebar.
    private var isLookup: Bool { all.first?.kind == .lookup }

    /// Width of the list column; the rest of the panel is the preview.
    private var listPaneWidth: CGFloat { isLookup ? 180 : 300 }

    /// Item shown in the preview pane: the item whose actions are being viewed, otherwise the selected row.
    private var previewItem: SpotlightItem? {
        scope ?? (sel < results.count ? results[sel] : nil)
    }

    private var targetPanelHeight: CGFloat {
        Metric.barHeight + (expanded ? SpotlightSpec.lowerHeight(rows: rowSlots) : 0)
    }

    /// Icon at the end of the bar: the item whose actions are being viewed, otherwise the top result.

    /// Home: the empty field, showing pinned items and then suggestions as the usual list.
    private var isHome: Bool {
        showingSuggestions && query.isEmpty && browse == nil && tagStack.isEmpty && scope == nil
            && activeCommand == nil
    }

    private var chipLabel: String? {
        scope?.name ?? activeCommand.map { $0 == Self.tagsCommand ? "Tags" : ":" + $0 }
            ?? (tagStack.isEmpty ? browse?.label : nil)
    }

    /// Changes when the actions scope or the search tag changes.
    private var chipKey: String { "\(scope?.id ?? "")|\(tagStack.map(\.keyword).joined(separator: "+"))" }

    private var placeholder: String {
        if let scope { return "Actions for \(scope.name)" }
        if activeCommand == Self.tagsCommand { return "Find a tag, then ⏎" }
        if let activeCommand { return SpotlightCommands.placeholder(for: activeCommand) }
        if let tag {
            // "search in the downloads folder", "search .psd files", "search YouTube".
            if let files = tag.files {
                if files.contentSearch { return "search inside your files" }
                if !files.folders.isEmpty, files.extensions.isEmpty, files.contentTypes.isEmpty {
                    return "search in the \(tag.name.lowercased()) folder"
                }
                return "search \(tag.name.lowercased())"
            }
            return "search \(tag.name)"
        }
        if inOCR { return "Search text in images & PDFs" }
        if let browse { return "Search in \(browse.label)" }
        return "Lumio Search"
    }

    private var introActive: Bool { !reduceMotion && Date() < introUntil }
    private var isDark: Bool { colorScheme == .dark }
    private var palette: SpotlightPalette { .of(colorScheme) }
    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: themeStore.settings.cornerRadius(side: Metric.barHeight), style: .continuous)
    }

    /// Open pop springs vertically only; the width stays fixed. The launch zoom stays uniform.
    private var clusterScaleX: CGFloat {
        if reduceMotion { return 1 }
        return launching ? SpotlightMotion.launchScale : 1
    }

    private var clusterScaleY: CGFloat {
        if reduceMotion { return 1 }
        if launching { return SpotlightMotion.launchScale }
        return shownScale ? 1 : SpotlightMotion.appearScale
    }

    private var clusterOffset: CGFloat {
        reduceMotion || shownScale || launching ? 0 : SpotlightMotion.appearOffsetY
    }

    /// Reduce motion: every animation becomes a short fade.
    private func motion(_ animation: Animation) -> Animation {
        reduceMotion ? SpotlightMotion.reduced : animation
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Clicking outside the glass cluster closes it, like Spotlight.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { point in
                    if !clusterContains(point) { hide() }
                }

            VStack(alignment: .leading, spacing: 14) {
                cluster
                    .scaleEffect(x: clusterScaleX, y: clusterScaleY, anchor: UnitPoint(x: 0.5, y: 0.3))
                    .offset(y: clusterOffset)
                    .opacity(shownAlpha ? 1 : 0)
                toastView
            }
            .padding(.leading, SpotlightWindowSizing.margin)
            .padding(.top, SpotlightWindowSizing.margin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(modeHooks)
        .onChange(of: idle) { _, isIdle in
            if !isIdle { quickFocus = nil }
        }
        .onChange(of: query) {
            quickFocus = nil
            sel = 0
            filter = nil
            // Typed more after Enter: that Enter belonged to the old text, drop it.
            activateWhenReady = false
            refresh()
        }
        // Entering / leaving actions (⌘K) or a search tag (⇥ / ⌫) re-runs the search.
        .onChange(of: chipKey) { refresh() }
        .onChange(of: browse) { _, tab in
            sel = 0
            filter = nil
            closeClipPreview()
            // The OCR worker only ever starts here: opening the OCR tab brings the index up to
            // date (new / changed files, at most every 15 min). Nothing else runs OCR.
            if tab == .content { ContentIndex.shared.refreshIfStale() }
            refresh()
        }
        .onChange(of: filter) { sel = 0 }
        .onChange(of: sel) { armedConfirm = nil }
        .onChange(of: targetPanelHeight) { _, height in
            // Panel height animates SEPARATELY: result rows change instantly, only the
            // bottom edge of the glass slides to its new position.
            let delay = resizeDelay
            resizeDelay = 0
            withAnimation(motion(SpotlightMotion.resize).delay(delay)) { panelHeight = height }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookToggleWindowRequested)) { _ in
            toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookHideLauncherRequested)) { _ in
            hide()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookOpenTabRequested)) { note in
            guard let raw = note.object as? String else { return }
            if raw.hasPrefix(HotKeyAction.tagPrefix) {
                openTagFromHotKey(String(raw.dropFirst(HotKeyAction.tagPrefix.count)))
            } else if let tab = SpotlightKind(rawValue: raw) {
                openFromHotKey(tab)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookActivateLauncherRequested)) { _ in
            show()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hide(restore: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookReloadConfigRequested)) { _ in
            reloadConfig()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookRefocusInputRequested)) { _ in
            if isOpen { focusField() }
        }
        // `lumio <mode>` arriving while this instance is already up.
        .onReceive(DistributedNotificationCenter.default().publisher(for: LaunchModes.deliveryNotification)) { note in
            if let text = note.object as? String { applyLaunchQuery(text) }
        }
        .onAppear {
            keyMonitor.start { handleKey($0) }
            loadRetention()
            // Quick Look is a global panel with no handle on the store, and clip rows carry
            // titles only: it asks the launcher for the text.
            SpotlightQuickLook.clipText = { [clipboardStore] id in await clipboardStore.content(of: id) }
            // A cold `lumio <mode>`: this process launched to serve it.
            if let pending = LaunchModes.pendingQuery {
                LaunchModes.pendingQuery = nil
                DispatchQueue.main.async { applyLaunchQuery(pending) }
            }
        }
    }

    /// Hooks for the legacy launcher modes, split out of `body` so the compiler
    /// can type-check it.
    private var modeHooks: SpotlightModeHooks {
        SpotlightModeHooks(
            activeCommand: activeCommand,
            previewID: previewItem?.id,
            processModel: processModel,
            clipboardStore: clipboardStore,
            onCommandChange: { refresh() },
            onPreviewChange: {
                armedKillPID = nil
                armedConfirm = nil
                // Processes: load details (memory, user, command line) on selection.
                if let item = previewItem, item.kind == .process, let pid = item.pid {
                    processModel.loadDetail(pid: pid)
                }
            },
            // Mode data arriving later (process snapshot, new clip): rebuild the rows.
            onProcesses: {
                if activeCommand == SpotlightCommands.kill || isMode(.process) { refresh() }
            },
            onClips: { if isMode(.clip) { refresh() } },
            onImages: { if isMode(.clip) { refresh() } }
        )
    }

    // MARK: - Glass cluster: panel + 4 round buttons

    private var cluster: some View {
        SpotlightGlassGroup(spacing: Metric.quickGap + 2) {
            HStack(alignment: .top, spacing: Metric.quickGap) {
                panel
                if idle {
                    ForEach(Array(Self.quickItems.enumerated()), id: \.element.id) { index, item in
                        quickButton(item, index: index)
                    }
                }
            }
        }
    }

    private var panel: some View {
        // Panel width animates (430 ↔ 660) when the 4 round buttons split/merge. The content
        // below the bar and the top-hit icon are laid out up front at the FINAL width, anchored to the
        // left edge: the glass edge just gradually reveals them. Laying out at the animating width
        // would drag the scrollbar, icon and right-hand text sliding from left to right.
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            lower
                .frame(width: Metric.panelWidth)
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
        .clipShape(panelShape)
        .contentShape(panelShape)
        .spotlightGlass(panelShape, id: "spotlight.panel", in: glassSpace, isDark: isDark)
    }

    private func quickButton(_ item: SpotlightQuickItem, index: Int) -> some View {
        let focused = quickFocus == index
        let shape = RoundedRectangle(cornerRadius: themeStore.settings.cornerRadius(side: Metric.quickSize), style: .continuous)
        return Button {
            quickFocus = nil
            toggleBrowse(item.kind)
        } label: {
            Image(systemName: item.icon)
                .font(.system(size: 21, weight: focused ? .semibold : .regular))
                .foregroundStyle(browse == item.kind || focused ? HierarchicalShapeStyle.primary : .secondary)
                .modifier(SpotlightPopIn(animation: reduceMotion ? nil : motion(SpotlightMotion.quickIcon(index))))
                .frame(width: Metric.quickSize, height: Metric.quickSize)
                .contentShape(shape)
                // Tab focus (idle only): a soft fill + ring, like the selected row.
                .background(shape.fill(palette.pillOn).opacity(focused ? 1 : 0))
                .overlay(shape.strokeBorder(Color.primary.opacity(focused ? 0.35 : 0), lineWidth: 1.5))
                .scaleEffect(focused ? 1.06 : 1)
                .animation(motion(SpotlightMotion.chip), value: focused)
        }
        .buttonStyle(.plain)
        .spotlightGlass(
            RoundedRectangle(cornerRadius: themeStore.settings.cornerRadius(side: Metric.quickSize), style: .continuous),
            id: "spotlight.quick.\(item.kind.rawValue)",
            in: glassSpace,
            interactive: true,
            isDark: isDark
        )
        .help("\(item.label)  ⌘\(index + 1)")
        .accessibilityLabel(item.label)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 15) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Metric.glassIconSize, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)

            if let chipLabel {
                Text(chipLabel)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(palette.pillOn, in: Capsule())
                    // The chip takes its space immediately while the text slides gradually, so the two have to
                    // be out of step or the text would overlap the chip: on enter, wait for the text to slide away
                    // before showing; on exit, dissolve quickly before the text comes back.
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .leading)
                            .combined(with: .opacity)
                            .animation(motion(SpotlightMotion.chip).delay(0.1)),
                        removal: .opacity.animation(.easeOut(duration: 0.08))
                    ))
            }

            // Search tags: one chip each, like Fluent Search (`documents` `.docx` resume).
            if scope == nil, activeCommand == nil {
                ForEach(Array(tagStack.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(item.name)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(palette.pillOn, in: Capsule())
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .leading)
                            .combined(with: .opacity)
                            .animation(motion(SpotlightMotion.chip).delay(0.1)),
                        removal: .opacity.animation(.easeOut(duration: 0.08))
                    ))
                }
            }

            // The legacy launcher's input field: the caret SLIDES to its new position while typing (still
            // while typing, blinking when paused) instead of jumping per character.
            // Enter goes through onSubmit (respecting an input method that is committing text); other
            // navigation keys: see handleKey (local key monitor).
            SmoothCaretTextField(
                text: $query,
                placeholder: placeholder,
                isFocused: $isFocused,
                font: .systemFont(ofSize: Metric.queryFontSize),
                onSubmit: { activate() }
            )
            .frame(maxWidth: .infinity)

            // What Tab would do right now ("press TAB to search in Downloads"), like Fluent Search.
            if let tabHint {
                // fixedSize: the text field is greedy and would otherwise squeeze this to nothing.
                Text(tabHint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, Metric.barPadding)
        .frame(height: Metric.barHeight)
    }

    // MARK: - Lower part (always built; the panel clips it to the animating height)

    private var lower: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)
                .padding(.horizontal, 14)
            resultsArea
            footer
                .frame(height: Metric.footerHeight)
        }
        .frame(height: SpotlightSpec.lowerHeight(rows: rowSlots), alignment: .top)
        .opacity(expanded ? 1 : 0)
        .animation(motion(expanded ? SpotlightMotion.contentIn : SpotlightMotion.contentOut), value: expanded)
        .allowsHitTesting(expanded)
    }

    /// Filter pills, then the list on the left and the preview on the right.
    @ViewBuilder
    private var resultsArea: some View {
        pillsRow
            .frame(height: Metric.pillsHeight)
            .padding(.top, Metric.lowerTopInset)
        // Split INSIDE the panel: list on the left, preview on the right.
        // Clipboard: just the list, full width.
        HStack(spacing: 0) {
            listView
                .frame(width: showsPreview ? listPaneWidth : Metric.panelWidth)
            if showsPreview {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(palette.divider)
                        .frame(width: 1)
                        .padding(.vertical, 8)
                    previewPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity)
            }
        }
        .frame(height: SpotlightSpec.listHeight(rows: rowSlots))
    }

    /// Right half of the panel: preview of the selected row (or the item whose actions are open).
    private var previewPane: some View {
        ZStack(alignment: .topLeading) {
            if let item = previewItem, item.kind == .clip || item.kind == .clipImage {
                SpotlightClipPreview(
                    item: item, details: clipDetails(for: item), store: clipboardStore)
                    .id(item.id)
            } else if let item = previewItem {
                SpotlightPreviewView(
                    item: item,
                    chips: previewChips(for: item),
                    showsPreview: item.kind == .folder ? previewFolders : previewFiles,
                    onTogglePreview: { togglePreview(for: item) },
                    actions: previewActions(for: item),
                    processDetail: item.pid.flatMap { processModel.details[$0] },
                    processCPU: item.pid.flatMap { processModel.cpu[$0] },
                    measuringCPU: item.pid.map { processModel.measuringCPU.contains($0) } ?? false,
                    onOpenPath: { path, isFolder in openFromPreview(path, isFolder: isFolder) },
                    onLookup: { word in
                        openTab(.lookup, text: word)
                        focusField()
                    },
                    translation: translation
                )
                .id(item.id)
            }
        }
        .background(QuickLookSourceAnchor())
        // Changing rows swaps the preview content IMMEDIATELY (like the legacy launcher): cross-fading
        // two files makes their text overlap. The sliding selection bar is enough.
        .animation(nil, value: previewItem?.id)
    }

    private var pillsRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metric.pillGap) {
                    pillButton(label: "All", active: filter == nil && !inModeTab) {
                        if inModeTab { leaveModeTab() } else { filter = nil }
                    }
                        .id(Self.allPillID)
                    ForEach(kinds) { kind in
                        pillButton(label: kind.label, active: filter == kind) {
                            filter = (filter == kind) ? nil : kind
                        }
                        .id(kind.rawValue)
                    }
                    ForEach(shownModeTabs) { tab in
                        pillButton(label: tab.tabLabel, active: browse == tab) {
                            toggleBrowse(tab)
                        }
                        .id(tab.rawValue)
                    }
                }
                .padding(.horizontal, 14)
            }
            // Tab can land on a pill that is scrolled out of view: bring it in.
            .onChange(of: filter) { _, kind in
                withAnimation(motion(SpotlightMotion.chip)) {
                    proxy.scrollTo(kind?.rawValue ?? Self.allPillID)
                }
            }
            .onChange(of: browse) { _, tab in
                let id = tab.flatMap { SpotlightKind.modeTabs.contains($0) ? $0.rawValue : nil }
                withAnimation(motion(SpotlightMotion.chip)) {
                    proxy.scrollTo(id ?? Self.allPillID)
                }
            }
        }
    }

    private static let allPillID = "pill-all"

    /// Tool tab pills: the visible ones, plus a hidden tab while it is open (from a round
    /// button or a command) so the row still shows where you are.
    private var shownModeTabs: [SpotlightKind] {
        SpotlightKind.modeTabs.filter { SpotlightKind.visibleModeTabs.contains($0) || $0 == browse }
    }

    /// Tab / Shift+Tab: move to the next / previous pill (All → Applications → … → tools → OCR → All).
    /// Landing on OCR or a tool switches to its search; leaving goes back to the name search.
    private func cycleFilter(_ step: Int) {
        // Only the group pills the user can actually see. With the field emptied the panel is
        // collapsed but `all` still holds the old results (kept so they fade out), and their
        // groups would otherwise be invisible stops: Tab seemed to do nothing for a few presses.
        let groups = expanded && !inModeTab ? kinds : []
        let options: [SpotlightKind?] = [nil] + groups + SpotlightKind.visibleModeTabs.map(Optional.some)
        let current = inModeTab ? (options.firstIndex(of: browse) ?? 0) : (options.firstIndex(of: filter) ?? 0)
        let next = options[(current + step + options.count) % options.count]
        if let next, SpotlightKind.modeTabs.contains(next) {
            filter = nil
            // A Lumio tab replaces a search tag chip (GitHub, YouTube…): never both at once.
            withAnimation(motion(SpotlightMotion.chip)) { scope = nil; tagStack = []; browse = next }
        } else {
            if inModeTab { leaveModeTab() }
            filter = next
        }
    }

    /// `~/Clients/Acme` or `/Volumes/Work/` typed in the field, when it is a folder.
    private static func typedFolder(_ text: String) -> String? {
        guard text.hasPrefix("/") || text.hasPrefix("~") else { return nil }
        let path = (text as NSString).expandingTildeInPath
        return isDirectory(path) ? (path as NSString).standardizingPath : nil
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Opens a tool tab with some text in the field (Dictionary from a linked word, `lumio <mode>`).
    private func openTab(_ tab: SpotlightKind?, text: String) {
        withAnimation(motion(SpotlightMotion.chip)) {
            scope = nil
            activeCommand = nil
            filter = nil
            if tab != nil { tagStack = [] }  // a Lumio tab replaces a search tag chip
            browse = tab
        }
        query = text
        focusField()
    }

    private func leaveModeTab() {
        withAnimation(motion(SpotlightMotion.chip)) { browse = nil }
    }

    private func pillButton(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            focusField()
        } label: {
            Text(label)
                .font(.system(size: 14.5, weight: active ? .medium : .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(active ? palette.pillOn : palette.pill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var listView: some View {
        Group {
            if results.isEmpty {
                Text("No results for “\(shownQuery)”.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                resultRow(item, selected: index == sel)
                                    .modifier(SpotlightDragSource(item: item))
                                    .id(item.id)
                                    .modifier(SpotlightRiseIn(
                                        animation: introActive ? motion(SpotlightMotion.rowRise(index)) : nil
                                    ))
                                    .transition(SpotlightMotion.rowSwap)
                                    .onTapGesture {
                                        // Mouse click: open exactly the row being seen, no waiting.
                                        sel = index
                                        run(item)
                                    }
                                    .onHover { hovering in
                                        // Ignore hovers caused by the list changing under a stationary
                                        // pointer — only accept them when the mouse actually moves.
                                        if hovering, mouseGate.moved() {
                                            if sel != index {
                                                withAnimation(motion(SpotlightMotion.selectionGlide)) { sel = index }
                                            }
                                            hoveredRow = index
                                            scheduleClipPreview()
                                        } else if !hovering, hoveredRow == index {
                                            hoveredRow = nil
                                            clipPreviewTask?.cancel()
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, Metric.listInsetTop)
                        .padding(.bottom, Metric.listInsetBottom)
                    }
                    .spotlightThinScroller(isDark: isDark)
                    .onChange(of: scrollTarget) { _, target in
                        // Scroll along with the selection bar, in step with its slide.
                        guard let target else { return }
                        if scrollWraps {
                            // Top <-> bottom: jump, so rows sliding under a still pointer can't steal the selection.
                            mouseGate.reset()
                            proxy.scrollTo(target, anchor: sel == 0 ? .top : .bottom)
                        } else {
                            withAnimation(motion(SpotlightMotion.selectionGlide)) { proxy.scrollTo(target) }
                        }
                    }
                }
            }
        }
    }

    private func togglePin(_ item: SpotlightItem) {
        if item.kind == .clip, let id = item.clipID {
            clipboardStore.togglePin(id: id)
        } else if item.kind == .clipImage, let id = item.payload {
            clipboardStore.toggleImagePin(id: id)
        } else {
            return
        }
        toast(item.isPinned ? "Unpinned" : "Pinned")
    }

    /// Removes the clip from history. Returns false when `item` isn't a clip.
    @discardableResult
    private func deleteClip(_ item: SpotlightItem) -> Bool {
        guard item.kind == .clip || item.kind == .clipImage else { return false }
        // Keep the cursor on the same row: the next row slides up into it. Set BEFORE deleting,
        // since the store's change re-publishes the list right away (publish would reset to 0).
        let keep = sel
        keepSelOnPublish = keep
        if item.kind == .clip, let id = item.clipID {
            clipboardStore.deleteEntry(id: id)
            toast("Clipboard item deleted")
        } else if item.kind == .clipImage, let id = item.payload {
            clipboardStore.deleteImageEntry(id: id)
            toast("Image deleted")
        }
        all.removeAll { $0.id == item.id }
        sel = min(keep, max(results.count - 1, 0))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if keepSelOnPublish == keep { keepSelOnPublish = nil }
        }
        return true
    }

    /// One list row. Everything the row draws is passed by value (the row skips its body when
    /// none of it changed); the two clip actions are closures over this launcher's state.
    private func resultRow(_ item: SpotlightItem, selected: Bool) -> some View {
        SpotlightRow(
            item: item.kind == .translation ? translationRow(item) : item,
            selected: selected,
            armed: armedKillPID != nil && item.pid == armedKillPID,
            thumbnail: item.kind == .clipImage
                ? item.iconPath.flatMap { RowIconCache.thumbnail(forFile: $0) }
                : nil,
            running: item.kind == .app && (item.iconPath ?? item.target).map(runningApps.contains) == true,
            highlight: highlightWords(for: item),
            palette: palette,
            reduceMotion: reduceMotion,
            namespace: selectionSpace,
            onTogglePin: { togglePin(item) },
            onDelete: { deleteClip(item) }
        )
        .equatable()
    }

    /// tr": the translation on top, the target language below.
    private func translationRow(_ item: SpotlightItem) -> SpotlightItem {
        let name = translation.result(for: item.payload)?.text
            ?? (translation.failed(item.payload) ? "Couldn't translate" : "Translating…")
        return SpotlightItem(
            id: item.id, name: name, kind: item.kind, colors: item.colors,
            meta: item.meta, symbol: item.symbol, payload: item.payload
        )
    }

    /// Typed words to show in bold in `item`'s title (Fluent Search-style).
    private func highlightWords(for item: SpotlightItem) -> [String] {
        guard scope == nil, activeCommand == nil,
              [.app, .doc, .content, .folder, .url, .tab, .setting].contains(item.kind)
        else { return [] }
        // The text these rows were found for, not the live field: a keystroke then leaves the
        // rows alone (they skip their body) until its own results land, and stale rows never
        // bold letters they don't match.
        return shownQuery.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 2 }
    }

    /// Clipboard: what the side preview lists under the clip (app, copy times, count).
    private func clipDetails(for item: SpotlightItem) -> ClipboardClipDetails? {
        if item.kind == .clip, let id = item.clipID,
           let entry = clipboardStore.entries.first(where: { $0.id == id })
        {
            return ClipboardClipDetails(
                appBundleID: entry.appBundleID, firstCopiedAt: entry.firstCapturedAt,
                lastCopiedAt: entry.capturedAt, copyCount: entry.copyCount
            )
        }
        if item.kind == .clipImage, let hash = item.payload,
           let entry = clipboardStore.imageEntries.first(where: { $0.id == hash })
        {
            return ClipboardClipDetails(
                appBundleID: entry.appBundleID, firstCopiedAt: entry.firstCapturedAt,
                lastCopiedAt: entry.capturedAt, copyCount: entry.copyCount, imageSize: item.meta
            )
        }
        return nil
    }

    /// Clipboard: resting on a row (mouse or arrow keys) for `clipPreviewDelay` opens the side preview.
    private func scheduleClipPreview() {
        guard isClipboard, !clipPreviewShown else { return }
        clipPreviewTask?.cancel()
        clipPreviewTask = Task { @MainActor in
            try? await Task.sleep(for: Self.clipPreviewDelay)
            guard !Task.isCancelled, isOpen, !dismissing, isClipboard else { return }
            withAnimation(motion(SpotlightMotion.chip)) { clipPreviewShown = true }
        }
    }

    private func closeClipPreview() {
        clipPreviewTask?.cancel()
        clipPreviewTask = nil
        clipPreviewShown = false
    }

    /// Secondary line under the name. Apps don't need one (the name is enough); action rows show the item name.
    private func rowMeta(_ item: SpotlightItem) -> String? {
        switch item.kind {
        case .app: return nil
        case .cmd: return nil
        default: return item.meta ?? item.kind.label
        }
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12))
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(palette.kbd, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            // Settings, one click away (also ⌘⇧Space), pinned to the leading edge of the footer.
            FooterIconButton(symbol: "gearshape", help: "Lumio Settings  ⌘⇧Space") { openSettings() }
            // One line only: when the bar is crowded the hint is cut, never wrapped.
            Text(footerHint)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Text("esc close")
                .fixedSize()
            Spacer(minLength: 8)
            if isClipboard {
                let armed = armedConfirm == "clipclear"
                Button {
                    confirm("clipclear", prompt: "Click Clear again to delete all clipboard history") {
                        clipboardStore.clearHistory()
                        toast("Clipboard cleared")
                    }
                } label: {
                    Text(armed ? "Click again to clear" : "Clear all")
                        .fixedSize()
                        .foregroundStyle(armed ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
            }
            if !results.isEmpty {
                Text("\(results.count) \(results.count == 1 ? "result" : "results")")
                    .fixedSize()
            }
            if sortMode != .relevance {
                Text("by \(sortMode.label.lowercased())")
                    .fixedSize()
            }
            FooterIconButton(symbol: "arrow.up.arrow.down", help: "Sort results  ⌥S") { showSortMenu() }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)
        }
    }

    private var footerHint: String {
        if scope != nil { return "↑↓ select   ⏎ run action" }
        if let tag, tag.isFileTag { return "↑↓ select   ⏎ open   ⇥ add a tag (pdf, image…)   ⌫ leave" }
        if let tag { return "↑↓ select   ⏎ search \(tag.name)   ⌫ leave tag" }
        if showingSuggestions, query.isEmpty, browse == nil {
            return "Recent   ↑↓ select   ⏎ open   yt ⇥ search tags   ⌥T all tags"
        }
        switch activeCommand {
        case Self.tagsCommand: return "↑↓ select   ⏎ use tag   ⌫ leave"
        case SpotlightCommands.kill: return "⏎ select, ⏎ again to force quit"
        case SpotlightCommands.emptyTrash: return "⏎ twice to empty   esc cancel"
        default: break
        }
        let mode = browse.map { SpotlightMode.forTab($0, query: query) ?? .search } ?? SpotlightMode.parse(query)
        var hint = "↑↓ select   " + mode.footerHint
        let previewable = switch mode {
        case .search, .clipboard: true
        default: false
        }
        if previewable, let combo = SpotlightQuickLook.shortcut {
            hint += "   \(combo.display) quick look"
        }
        return hint
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastView: some View {
        if let toastMsg {
            Text(toastMsg)
                .font(.system(size: 14.5, weight: .medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .spotlightGlass(Capsule(), in: glassSpace, isDark: isDark)
                .frame(width: Metric.panelWidth)
                .transition(.offset(y: -12).combined(with: .opacity))
        }
    }

    private func toast(_ msg: String) {
        withAnimation(motion(SpotlightMotion.toast)) { toastMsg = msg }
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1900))
            guard !Task.isCancelled else { return }
            withAnimation(motion(SpotlightMotion.toast)) { toastMsg = nil }
        }
    }

    // MARK: - Search + state

    /// Text / browsed group / action mode changed: search again. The list changes WITHOUT
    /// animation (like a native list); only the panel expand/collapse and glass droplets move.
    private func refresh() {
        searchTask?.cancel()
        searchTask = nil
        fileTask?.cancel()
        fileTask = nil
        ocrPollTask?.cancel()
        ocrPollTask = nil
        // Has text: the 4 round buttons merge back into the bar immediately, without waiting for results.
        pokeIdle()

        if let scope {
            publish(SpotlightBackend.actionRows(for: scope, filter: query))
            return
        }
        if let activeCommand {
            switch activeCommand {
            case SpotlightCommands.kill: publish(SpotlightModeRows.killTargets(processModel, term: query))
            case SpotlightCommands.emptyTrash: publish(SpotlightModeRows.emptyTrash(itemCount: trashCount))
            case SpotlightCommands.help: publish(SpotlightModeRows.help(query))
            case Self.tagsCommand: publish(SpotlightBackend.tagBrowserRows(query))
            default: publish([])
            }
            return
        }
        if let tag {
            refreshTag(tag)
            return
        }
        if let browse, let mode = SpotlightMode.forTab(browse, query: query) {
            _ = refreshMode(mode)
            return
        }
        if browse == nil, refreshMode(SpotlightMode.parse(query)) { return }

        let request = SpotlightRequest(text: query, browse: browse)
        if inOCR {
            searchContent(request.term)
            return
        }
        guard !request.isEmpty else {
            if suggestionsEnabled, isOpen {
                refreshSuggestions()
                return
            }
            // Empty field: collapse the panel. `all` is kept so the list fades out with the panel.
            activateWhenReady = false
            showingSuggestions = false
            if expanded { setExpanded(false) }
            return
        }
        showingSuggestions = false

        let engineQuery = SpotlightBackend.engineQuery(for: request)
        // First keystroke (panel not expanded yet) searches immediately; further typing waits a short beat.
        let debounce: Duration = expanded ? SpotlightBackend.debounce : .zero
        searchTask = Task { @MainActor in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            // The core holds the engine read lock while searching: run off the main thread.
            let wantsURLs = request.browse == nil && request.term.count >= 2
            let urlQuery = request.term
            let urlLimit = AppConstants.Launcher.WebURL.recentLimit
            // Second pass, started NOW so it runs alongside the core search: files from anywhere
            // on the Mac (Spotlight), bookmarks and history (read like a browser extension would).
            let wantsExtras = request.browse == nil && urlQuery.count >= 3 && !urlQuery.hasPrefix(":")
                && !urlQuery.hasPrefix(">")
            let extrasTask: Task<SpotlightBackend.Extras, Never>? = wantsExtras
                ? Task.detached(priority: .userInitiated) {
                    SpotlightBackend.Extras(
                        files: SpotlightFiles.search(term: urlQuery, scope: nil, limit: 25),
                        bookmarks: BrowserBookmarks.search(urlQuery, limit: 2),
                        history: BrowserHistory.search(urlQuery, limit: 3),
                        blocked: BrowserHistory.isBlocked()
                    )
                } : nil
            // Web suggestions are the only network call: fetched on their own, never awaited
            // by the file results.
            let suggestionsTask: Task<[String], Never>? = wantsExtras && webSuggestMode == .always
                ? Task.detached(priority: .utility) { await WebSuggestions.fetch(urlQuery, youtube: false, limit: 3) }
                : nil
            let (found, recents, tabs, windows) = await Task.detached(priority: .userInitiated) {
                let found = EngineBridge.shared.search(query: engineQuery.text, limit: engineQuery.limit)
                let recents = wantsURLs
                    ? EngineBridge.shared.recentURLs(query: urlQuery, limit: urlLimit)
                    : []
                let tabs = wantsURLs
                    ? BrowserTabs.shared.search(urlQuery, limit: SpotlightBackend.tabLimit)
                    : []
                // Windows of other apps (a browser's are already listed tab by tab).
                let windows = wantsURLs && urlQuery.count >= 3
                    ? OpenWindows.shared.search(urlQuery, limit: 3, skipping: { BrowserTabs.isBrowser(appPath: $0) })
                    : []
                return (found, recents, tabs, windows)
            }.value
            // Text changed while waiting: these results are stale.
            guard !Task.isCancelled else { return }
            searchTask = nil
            publish(SpotlightBackend.rows(from: found, for: request, recentURLs: recents, tabs: tabs, windows: windows))
            guard let extrasTask else { return }
            fileTask = Task { @MainActor in
                let extras = await extrasTask.value
                guard !Task.isCancelled else { return }
                republish(SpotlightBackend.addingExtras(extras, term: urlQuery, to: all))
                if let suggestionsTask {
                    let suggestions = await suggestionsTask.value
                    guard !Task.isCancelled else { return }
                    republish(SpotlightBackend.addingSuggestions(suggestions, to: all))
                }
                fileTask = nil
            }
        }
    }

    /// A file or folder clicked in the preview's folder listing: open it, remember the pick
    /// for this text like any other result, and close the launcher.
    private func openFromPreview(_ path: String, isFolder: Bool) {
        guard FileManager.default.fileExists(atPath: path) else {
            toast("This item no longer exists")
            return
        }
        if isFolder {
            FileManagerApp.openFolder(path)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        if tagStack.isEmpty, browse == nil {
            UsageLearning.shared.record(SpotlightItem(
                id: "file|" + path, name: (path as NSString).lastPathComponent, kind: isFolder ? .folder : .doc,
                meta: PathDisplay.directory(of: path), target: path, iconPath: path
            ), query: query)
        }
        hide(restore: false, launched: true)
    }

    /// Closes the launcher and opens the Settings window.
    private func openSettings() {
        hide(restore: false)
        SettingsWindowController.shared.show()
    }

    /// Replaces the rows of the SAME search with a fuller list, keeping the selection where it is.
    private func republish(_ rows: [SpotlightItem]) {
        guard rows.map(\.id) != all.map(\.id) || rows.map(\.meta) != all.map(\.meta) else { return }
        keepSelOnPublish = sel
        publish(rows)
        keepSelOnPublish = nil
    }

    /// Search tag active: the site search row, its open tabs and recently visited pages.
    private func refreshTag(_ tag: SearchTag) {
        showingSuggestions = false
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let debounce: Duration = expanded ? SpotlightBackend.debounce : .zero
        searchTask = Task { @MainActor in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            if let scope = tag.files {
                // File tag: files from anywhere on the Mac in that folder / of that kind.
                let hits = await Task.detached(priority: .userInitiated) {
                    SpotlightFiles.search(term: term, scope: scope, limit: SpotlightBackend.resultLimit)
                }.value
                guard !Task.isCancelled else { return }
                searchTask = nil
                let rows = SpotlightBackend.fileRows(hits)
                publish(rows.isEmpty ? [SpotlightItem(
                    id: "tag|empty",
                    name: scope.contentSearch && term.isEmpty ? "Type a word to search inside your files"
                        : term.isEmpty ? "Nothing here yet" : "No files match “\(term)”",
                    kind: .help, colors: "#a7aeb8,#5e6670", meta: tag.name, symbol: tag.symbol
                )] : rows)
                return
            }
            if tag.windows {
                // `windows` ⇥: every open window, or the ones matching the text.
                searchTask = nil
                guard OpenWindows.isTrusted else {
                    // Off or stale? Word the row for what was last found, then look again.
                    let stale: Bool = if case .stale = AccessibilityDoctor.shared.lastState { true } else { false }
                    publish([SpotlightItem(
                        id: Self.windowsBlockedRow,
                        name: stale ? "The Accessibility permission has gone stale"
                            : "Window search needs the Accessibility permission",
                        kind: .setting, colors: stale ? "#ff8a80,#d6453a" : "#ffb36e,#f06a2e",
                        meta: stale ? "⏎ see what happened and reset it" : "⏎ check it and turn it on for Lumio",
                        target: OpenWindows.settingsURL, symbol: stale ? "exclamationmark.lock.fill" : "lock.fill"
                    )])
                    if AccessibilityDoctor.shared.lastState == nil {
                        AccessibilityDoctor.shared.check { _ in
                            if isOpen, !dismissing, self.tag?.windows == true { refresh() }
                        }
                    }
                    return
                }
                let rows = OpenWindows.shared.search(term, limit: SpotlightBackend.resultLimit)
                    .map(SpotlightBackend.item(from:))
                publish(rows.isEmpty ? [SpotlightItem(
                    id: "tag|empty", name: term.isEmpty ? "No open windows found" : "No window matches “\(term)”",
                    kind: .help, colors: "#a7aeb8,#5e6670", meta: tag.name, symbol: tag.symbol
                )] : rows)
                return
            }
            if tag.settingsOnly {
                // `settings` ⇥: System Settings panes (they live among the apps in the core).
                let found = await Task.detached(priority: .userInitiated) {
                    EngineBridge.shared.search(query: "a\"" + term, limit: 120)
                }.value
                guard !Task.isCancelled else { return }
                searchTask = nil
                let rows = found.compactMap(SpotlightBackend.item(from:)).filter { $0.kind == .setting }
                publish(rows.isEmpty ? [SpotlightItem(
                    id: "tag|empty", name: term.isEmpty ? "Type to find a setting" : "No settings match “\(term)”",
                    kind: .help, colors: "#a7aeb8,#5e6670", meta: tag.name, symbol: tag.symbol
                )] : rows)
                return
            }
            if tag.bookmarks != nil || tag.history {
                // `bookmark` ⇥ / a bookmark folder's tag: bookmarks, folder order when empty.
                // `history` ⇥: the whole history, most visited and recent first. `browser` ⇥: both.
                let scope = tag.bookmarks
                let wantsHistory = tag.history
                let (bookmarks, pages) = await Task.detached(priority: .userInitiated) {
                    (scope.map { BrowserBookmarks.search(term, folder: $0.folder, limit: SpotlightBackend.resultLimit) } ?? [],
                     wantsHistory ? BrowserHistory.search(term.isEmpty ? "http" : term, limit: 30) : [])
                }.value
                guard !Task.isCancelled else { return }
                searchTask = nil
                let listed = Set(bookmarks.map(\.url))
                let rows = SpotlightBackend.bookmarkRows(bookmarks)
                    + SpotlightBackend.historyRows(pages.filter { !listed.contains($0.url) })
                if rows.isEmpty, BrowserHistory.isBlocked() {
                    publish([SpotlightBackend.blockedRow])
                    return
                }
                publish(rows.isEmpty ? [SpotlightItem(
                    id: "tag|empty", name: term.isEmpty ? "Nothing found in your browsers" : "Nothing matches “\(term)”",
                    kind: .help, colors: "#a7aeb8,#5e6670",
                    meta: "Chrome, Edge, Brave, Arc, Vivaldi · Safari needs Full Disk Access", symbol: tag.symbol
                )] : rows)
                return
            }
            let (tabs, history) = await Task.detached(priority: .userInitiated) {
                (SpotlightBackend.tabs(for: tag, matching: term),
                 BrowserHistory.recent(for: tag, matching: term, limit: 12))
            }.value
            guard !Task.isCancelled else { return }
            searchTask = nil
            publish(SpotlightBackend.tagRows(tag: tag, term: term, tabs: tabs, history: history))
            // Then search suggestions for the site, like the browser's address bar.
            guard !term.isEmpty, webSuggestMode != .off else { return }
            let youtube = tag.domain?.contains("youtube.com") ?? false
            fileTask = Task { @MainActor in
                let suggestions = await WebSuggestions.fetch(term, youtube: youtube)
                guard !Task.isCancelled, !suggestions.isEmpty else { return }
                fileTask = nil
                var rows = all
                let shown = Set(rows.map { $0.name.lowercased() })
                let extra = SpotlightBackend.suggestionRows(
                    suggestions.filter { !shown.contains($0.lowercased()) }, tag: tag)
                rows.insert(contentsOf: extra, at: min(1, rows.count))
                keepSelOnPublish = sel
                publish(rows)
                keepSelOnPublish = nil
            }
        }
    }

    /// Empty field (Fluent-style): recently used apps and files, so ⏎ often opens what you want
    /// before you type. Off with `suggestions_on_open=false`.
    private func refreshSuggestions() {
        searchTask = Task { @MainActor in
            let recent = await Task.detached(priority: .userInitiated) {
                RecentItems.recent(apps: 5, files: 9)
            }.value
            guard !Task.isCancelled else { return }
            searchTask = nil
            // Your pins first, then what you use most, without repeating a pinned item.
            let pinned = pins.items.filter { item in
                guard let target = item.target, target.hasPrefix("/") else { return true }
                return FileManager.default.fileExists(atPath: target)
            }
            let pinnedTargets = Set(pinned.compactMap { $0.target?.lowercased() })
            let suggested = SpotlightBackend.suggestionRows(apps: recent.apps, files: recent.files)
                .filter { !pinnedTargets.contains(($0.target ?? "").lowercased()) }
            let rows = pinned + suggested
            guard !rows.isEmpty else {
                showingSuggestions = false
                if expanded { setExpanded(false) }
                return
            }
            showingSuggestions = true
            publish(rows)
        }
    }

    /// What Tab would turn into a search tag right now, and the text that stays in the field:
    ///   `yt cats` / `cats yt`   → YouTube + "cats" (keyword first or last)
    ///   `downloads`, `pdf`      → file tags; a second one stacks (`downloads` ⇥ `pdf` ⇥)
    ///   `~/Clients/Acme`        → that folder
    ///   a "press Tab" hint row  → its tag (typed `yout`)
    ///   the selected result     → what it belongs to, like Fluent Search: a folder → inside it,
    ///                             a file → its parent folder, a link / tab / history page → that
    ///                             website, a browser app → your bookmarks and history
    /// nil when nothing applies (Tab then cycles the filter pills).
    private func tagCandidate(keyword: String? = nil) -> (tag: SearchTag, rest: String)? {
        guard scope == nil, activeCommand == nil, !inModeTab else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Nothing typed: Tab only cycles Lumio's own pills, never a Fluent-style tag
        // from the selected result.
        if keyword == nil, trimmed.isEmpty { return nil }
        var found: (SearchTag, String)?
        if let keyword {
            if let named = SearchTags.tag(forKeyword: keyword) {
                // `cats yt` with the YouTube hint picked: keep "cats".
                let split = SearchTags.split(trimmed)
                found = (named, split?.tag.keyword == named.keyword ? split?.rest ?? "" : "")
            }
        } else if let path = Self.typedFolder(trimmed) {
            found = (.folder(path), "")
        } else if let split = SearchTags.split(trimmed) {
            found = (split.tag, split.rest)
        } else if tagStack.isEmpty, let hint = results.first(where: { $0.kind == .tagHint }),
                  let named = hint.payload.flatMap(SearchTags.tag(forKeyword:))
        {
            found = (named, "")
        } else if expanded, sel < results.count, let context = Self.contextTag(for: results[sel]) {
            // Narrowing to the selected result's home keeps the text for a folder you typed
            // towards ("downl" → Downloads starts clean), and clears it otherwise.
            found = (context, "")
        }
        guard let found else { return nil }
        // Lumio's own tabs (`apps`, `clipboard`…) and web tags don't stack.
        if !tagStack.isEmpty, found.0.mode != nil || tag?.stacked(with: found.0) == nil { return nil }
        // The same tag twice does nothing.
        if tagStack.contains(where: { $0.keyword == found.0.keyword }) { return nil }
        return found
    }

    /// The search tag a result belongs to (Fluent's "press TAB to search in …").
    private static func contextTag(for item: SpotlightItem) -> SearchTag? {
        switch item.kind {
        case .folder:
            guard let path = item.target, isDirectory(path) else { return nil }
            return .folder(path)
        case .doc, .content:
            // Fluent: "press TAB to search for psd files". The folder is ⌘R (Search in Parent Folder).
            guard let path = item.target, path.hasPrefix("/") else { return nil }
            let ext = (path as NSString).pathExtension.lowercased()
            return ext.isEmpty ? .folder((path as NSString).deletingLastPathComponent) : SearchTags.extensionTag(ext)
        case .tab, .url:
            guard let target = item.tab?.url ?? item.target,
                  let host = URLComponents(string: target)?.host, target.hasPrefix("http")
            else { return nil }
            return .site(host)
        case .app:
            guard let path = item.target, path.hasPrefix("/") else { return nil }
            if BrowserTabs.isBrowser(appPath: path) { return SearchTags.tag(forKeyword: "browser") }
            // Any other app: the files it opens (Photoshop → your PSDs), newest first.
            return AppDocuments.tag(forApp: path)
        default:
            return nil
        }
    }

    /// "press TAB to search in Downloads", shown at the end of the bar.
    private var tabHint: String? {
        guard expanded, isOpen, !isHome, let candidate = tagCandidate() else { return nil }
        // Kept short: it shares the bar with the text being typed.
        var name = candidate.tag.name
        if name.count > 24 { name = String(name.prefix(23)) + "…" }
        if candidate.tag.mode != nil { return "press TAB for \(name)" }
        if candidate.tag.keyword.hasPrefix("app:") { return "press TAB for its files" }
        if let files = candidate.tag.files, files.folders.isEmpty, files.extensions.count == 1,
           candidate.tag.keyword == files.extensions[0]
        {
            return "press TAB to search for \(files.extensions[0]) files"
        }
        return "press TAB to search in \(name)"
    }

    /// Tab (or ⏎ on a hint row): lock the tag in as a chip. False when nothing applies.
    private func enterTag(keyword: String? = nil) -> Bool {
        guard let (found, rest) = tagCandidate(keyword: keyword) else { return false }
        // `apps`, `content`, `clipboard`…: one of Lumio's own tabs rather than a chip.
        if let raw = found.mode, let kind = SpotlightKind(rawValue: raw) {
            openTab(kind, text: rest)
            return true
        }
        lockTag(found, rest: rest)
        return true
    }

    /// Adds `found` as a chip and leaves `rest` as the text.
    private func lockTag(_ found: SearchTag, rest: String) {
        withAnimation(motion(SpotlightMotion.chip)) {
            filter = nil
            browse = nil
            tagStack.append(found)
        }
        query = rest
        if !found.isFileTag {
            // Fresh tab list for this site; redraw if it changed meanwhile.
            BrowserTabs.shared.refresh(minInterval: 0.5) {
                if isOpen, !dismissing, tag != nil { refresh() }
            }
        }
        focusField()
    }

    // MARK: - Quick actions (preview pane)

    // MARK: - Pinning, rename, delete, Open With, preview toggle

    private func pinAction(for item: SpotlightItem) -> PreviewAction {
        let pinned = pins.isPinned(item)
        return PreviewAction(
            id: "pin", label: pinned ? "Unpin from Home" : "Pin to Home",
            symbol: pinned ? "pin.slash" : "pin", shortcut: "⌘⇧P"
        ) { toggleHomePin(item) }
    }

    /// ⌘⇧P / Pin action: keeps the result on the Home screen.
    private func toggleHomePin(_ item: SpotlightItem) {
        switch pins.toggle(item) {
        case true?: toast("Pinned \(item.name) to Home")
        case false?:
            toast("Unpinned \(item.name)")
            if isHome { refresh() }
        case nil: toast("This result can't be pinned")
        }
    }

    /// ⌥P / the eye button: details card ↔ preview, remembered per kind.
    private func togglePreview(for item: SpotlightItem) {
        if item.kind == .folder { previewFolders.toggle() } else { previewFiles.toggle() }
    }

    /// Rename… : a small native prompt with the current name.
    private func rename(_ item: SpotlightItem, path: String) {
        let alert = NSAlert()
        alert.messageText = "Rename “\(item.name)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = item.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // Select the name without its extension, like Finder.
        DispatchQueue.main.async {
            let stem = (item.name as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { focusField(); return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name, !newName.contains("/") else { focusField(); return }
        let destination = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(atPath: path, toPath: destination)
            toast("Renamed to \(newName)")
            Task.detached(priority: .utility) { _ = EngineBridge.shared.requestIndexRefresh() }
            // The row still shows the old name: search again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { refresh() }
        } catch {
            toast("Couldn't rename: \(error.localizedDescription)")
        }
        focusField()
    }

    private func deletePermanently(_ item: SpotlightItem, path: String) {
        do {
            try FileManager.default.removeItem(atPath: path)
            toast("Deleted \(item.name)")
            all.removeAll { $0.id == item.id }
            sel = min(sel, max(results.count - 1, 0))
            Task.detached(priority: .utility) { _ = EngineBridge.shared.requestIndexRefresh() }
        } catch {
            toast("Couldn't delete: \(error.localizedDescription)")
        }
    }

    /// Open With… : a menu of the apps that can open the file, the default one first.
    private func showOpenWithMenu(for path: String) {
        let fileURL = URL(fileURLWithPath: path)
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        guard !apps.isEmpty else { toast("No app can open this file"); return }
        let menu = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: fileURL)
        for app in apps.prefix(14) {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            let entry = MenuActionTarget.item(app == defaultApp ? "\(name) (default)" : name) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.open([fileURL], withApplicationAt: app, configuration: config) { _, _ in }
                hide(restore: false, launched: true)
            }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Tag chips for the detail card, like Fluent Search's: click one to narrow to it.
    private func previewChips(for item: SpotlightItem) -> [PreviewChip] {
        // Read so the late default-app chip (PreviewFacts) re-renders the pane.
        _ = previewFactsTick
        guard scope == nil, activeCommand == nil else { return [] }
        func lock(_ tag: SearchTag?) {
            guard let tag else { return }
            // Start a fresh scope from the chip rather than stacking onto whatever is active.
            withAnimation(motion(SpotlightMotion.chip)) { tagStack = [] }
            lockTag(tag, rest: "")
        }
        switch item.kind {
        case .doc, .content, .folder:
            guard item.isFileTarget, let path = item.target else { return [] }
            var chips: [PreviewChip] = []
            let isFolder = item.kind == .folder
            chips.append(PreviewChip(id: "kind", label: isFolder ? "folder" : "file", symbol: isFolder ? "folder" : "doc") {
                lock(SearchTags.tag(forKeyword: isFolder ? "folder" : "file"))
            })
            let ext = (path as NSString).pathExtension.lowercased()
            if !isFolder, !ext.isEmpty {
                chips.append(PreviewChip(id: "ext", label: "." + ext, symbol: "square.on.square") {
                    lock(SearchTags.extensionTag(ext))
                })
            }
            let parent = (path as NSString).deletingLastPathComponent
            chips.append(PreviewChip(
                id: "parent", label: PreviewFacts.displayName(isFolder ? path : parent), symbol: "folder"
            ) { lock(.folder(isFolder ? path : parent)) })
            if isFolder {
                chips.append(PreviewChip(id: "in", label: PreviewFacts.displayName(parent), symbol: "arrow.turn.left.up") {
                    lock(.folder(parent))
                })
            } else if let app = PreviewFacts.defaultApp(for: path, onLoad: { previewFactsTick &+= 1 }) {
                // The app that opens it: jump to that app's result. Looked up off the main
                // thread; the chip shows up one render later the first time.
                let name = PreviewFacts.displayName(app.path).replacingOccurrences(of: ".app", with: "")
                chips.append(PreviewChip(id: "app", label: name, appPath: app.path) {
                    withAnimation(motion(SpotlightMotion.chip)) { tagStack = [] }
                    query = name
                    focusField()
                })
            }
            return chips
        case .url, .tab:
            guard let link = item.tab?.url ?? item.target, let host = URLComponents(string: link)?.host else { return [] }
            var chips = [PreviewChip(id: "site", label: FaviconStore.normalize(host), symbol: "globe") { lock(.site(host)) }]
            if item.id.hasPrefix("bookmark|") {
                chips.append(PreviewChip(id: "bookmark", label: "bookmark", symbol: "bookmark") {
                    lock(SearchTags.tag(forKeyword: "bookmark"))
                })
            } else {
                chips.append(PreviewChip(id: "history", label: "history", symbol: "clock.arrow.circlepath") {
                    lock(SearchTags.tag(forKeyword: "history"))
                })
            }
            chips.append(PreviewChip(id: "browser", label: "browser", symbol: "star") {
                lock(SearchTags.tag(forKeyword: "browser"))
            })
            return chips
        case .app:
            return [PreviewChip(id: "apps", label: "apps", symbol: "square.grid.2x2") {
                withAnimation(motion(SpotlightMotion.chip)) { tagStack = [] }
                openTab(.app, text: "")
            }]
        default:
            return []
        }
    }

    /// The actions listed in the preview pane for `item`, like Fluent Search's result actions:
    /// the first is what ⏎ does.
    private func previewActions(for item: SpotlightItem) -> [PreviewAction] {
        guard scope == nil, activeCommand == nil else { return [] }
        let manager = FileManagerApp.name
        func finish(_ outcome: SpotlightOpener.Outcome) {
            switch outcome {
            case .launched: hide(restore: false, launched: true)
            case .message(let text): toast(text)
            }
        }
        func copy(_ text: String, _ message: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            toast(message)
        }
        let open = PreviewAction(id: "open", label: "Open", symbol: "arrow.up.forward.app", shortcut: "⏎") { run(item) }

        switch item.kind {
        case .app:
            guard let path = item.target, path.hasPrefix("/") else { return [] }
            let running = PreviewFacts.isRunning(path)
            var list = [PreviewAction(
                id: "open", label: running ? "Switch to App" : "Open",
                symbol: running ? "arrow.left.arrow.right" : "arrow.up.forward.app", shortcut: "⏎"
            ) { run(item) }]
            list.append(PreviewAction(id: "new", label: "Open New Instance", symbol: "plus.rectangle.on.rectangle") {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                config.activates = true
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { _, _ in }
                hide(restore: false, launched: true)
            })
            list.append(PreviewAction(id: "reveal", label: "Show in \(manager)", symbol: "folder", shortcut: "⌘F") {
                finish(SpotlightOpener.perform(.reveal, on: item))
            })
            if running {
                list.append(PreviewAction(id: "hide", label: "Hide", symbol: "eye.slash") {
                    finish(SpotlightOpener.perform(.hideApp, on: item))
                })
                list.append(PreviewAction(id: "quit", label: "Quit", symbol: "xmark.circle") {
                    SpotlightOpener.runningApp(at: path)?.terminate()
                    toast("Quit \(item.name)")
                })
                list.append(PreviewAction(id: "kill", label: "Force Quit", symbol: "xmark.octagon") {
                    SpotlightOpener.runningApp(at: path)?.forceTerminate()
                    toast("Force quit \(item.name)")
                })
            }
            list.append(PreviewAction(id: "copy", label: "Copy Path", symbol: "doc.on.doc", shortcut: "⌘⇧C") { copy(path, "Copied path") })
            list.append(pinAction(for: item))
            if AppDocuments.tag(forApp: path) != nil {
                list.append(PreviewAction(id: "files", label: "Search Its Files", symbol: "doc.on.doc", shortcut: "⇥") {
                    if let files = AppDocuments.tag(forApp: path) {
                        withAnimation(motion(SpotlightMotion.chip)) { tagStack = [] }
                        lockTag(files, rest: "")
                    }
                })
            }
            if PreviewFacts.canUninstall(path) {
                list.append(PreviewAction(id: "uninstall", label: "Uninstall…", symbol: "trash") {
                    if SpotlightOpener.runningApp(at: path) != nil {
                        toast("Quit \(item.name) first, then uninstall it")
                        return
                    }
                    confirm("uninstall|\(path)", prompt: "Click Uninstall again to move \(item.name) to the Trash") {
                        moveToTrash(item, path: path)
                    }
                })
            }
            return list

        case .window:
            return [
                PreviewAction(id: "open", label: "Switch to Window", symbol: "macwindow", shortcut: "⏎") { run(item) },
                PreviewAction(id: "close", label: "Close Window", symbol: "xmark.rectangle") {
                    if OpenWindows.shared.close(id: item.id) {
                        toast("Closed \(item.name)")
                        all.removeAll { $0.id == item.id }
                        sel = min(sel, max(results.count - 1, 0))
                    } else {
                        toast("Couldn't close that window")
                    }
                },
            ]

        case .doc, .content, .folder:
            guard item.isFileTarget, let path = item.target else { return [] }
            let isFolder = item.kind == .folder
            let inside = isFolder ? path : (path as NSString).deletingLastPathComponent
            // Fluent Search's file actions, in its order, with the Mac shortcut for each.
            var list = [open]
            list.append(PreviewAction(id: "reveal", label: "Show in \(manager)", short: "Show", symbol: "folder", shortcut: "⌘F") {
                finish(SpotlightOpener.perform(.reveal, on: item))
            })
            list.append(PreviewAction(
                id: "search", label: isFolder ? "Search Inside" : "Search in Parent Folder", short: "Search",
                symbol: "magnifyingglass", shortcut: "⌘R"
            ) { lockTag(.folder(inside), rest: "") })
            list.append(PreviewAction(id: "terminal", label: "Open in Terminal", short: "Terminal", symbol: "terminal", shortcut: "⌘T") {
                _ = performLocal(.openInTerminal, on: item)
            })
            if !isFolder {
                list.append(PreviewAction(id: "openwith", label: "Open With…", short: "Open With", symbol: "arrow.up.forward.square") {
                    showOpenWithMenu(for: path)
                })
                list.append(PreviewAction(id: "edit", label: "Open in Editor", short: "Edit", symbol: "pencil", shortcut: "⌘E") {
                    _ = performLocal(.openInEditor, on: item)
                })
            }
            list.append(PreviewAction(id: "copy", label: "Copy Path", short: "", symbol: "doc.on.doc", shortcut: "⌘⇧C") {
                copy(path, "Copied path")
            })
            list.append(PreviewAction(id: "copyfile", label: isFolder ? "Copy Folder" : "Copy File", symbol: "doc.on.clipboard") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([URL(fileURLWithPath: path) as NSURL])
                toast("Copied \(item.name): paste it in a folder or an app")
            })
            list.append(PreviewAction(id: "rename", label: "Rename…", symbol: "character.cursor.ibeam") { rename(item, path: path) })
            list.append(pinAction(for: item))
            if SpotlightBackend.trashAction(for: item) == .moveToTrash {
                list.append(PreviewAction(id: "trash", label: "Move to Trash", symbol: "trash", shortcut: "⌘D") {
                    _ = performLocal(.moveToTrash, on: item)
                })
                list.append(PreviewAction(id: "delete", label: "Delete Permanently", symbol: "minus.circle") {
                    confirm("delete|\(path)", prompt: "Click Delete Permanently again: \(item.name) can't be recovered") {
                        deletePermanently(item, path: path)
                    }
                })
            }
            return list

        case .url, .tab, .web:
            guard let link = item.tab?.url ?? item.target, link.hasPrefix("http") else { return [] }
            var list = [PreviewAction(
                id: "open", label: item.kind == .tab ? "Switch to Tab" : "Open",
                symbol: item.kind == .tab ? "arrow.left.arrow.right" : "arrow.up.forward.app", shortcut: "⏎"
            ) { run(item) }]
            list.append(PreviewAction(id: "copy", label: "Copy URL", symbol: "link", shortcut: "⌘⇧C") { copy(link, "Copied link") })
            // Fluent's "Search" (Ctrl+E): put the address back in the field to edit or re-search it.
            list.append(PreviewAction(id: "edit", label: "Edit in Search Field", symbol: "pencil") {
                query = link
                focusField()
            })
            if PinStore.target(of: item) != nil { list.append(pinAction(for: item)) }
            if item.kind != .web, let host = URLComponents(string: link)?.host, tagStack.isEmpty {
                list.append(PreviewAction(id: "site", label: "Search This Site", symbol: "magnifyingglass", shortcut: "⇥") {
                    lockTag(.site(host), rest: "")
                })
            }
            return list

        default:
            return []
        }
    }

    /// OCR tab: search the text inside images / PDFs (ContentIndex) instead of names.
    private func searchContent(_ term: String) {
        // First keystroke searches immediately; further typing waits a short beat.
        let debounce: Duration = expanded ? SpotlightBackend.debounce : .zero
        let limit = SpotlightBackend.resultLimit
        searchTask = Task { @MainActor in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            let (hits, status) = await Task.detached(priority: .userInitiated) {
                (ContentIndex.shared.search(term, limit: limit), ContentIndex.shared.status())
            }.value
            guard !Task.isCancelled else { return }
            searchTask = nil
            publish(SpotlightBackend.contentRows(hits: hits, term: term, status: status))
            // Only while nothing is listed: re-publishing real rows would reset the selection.
            if hits.isEmpty, status.indexing { scheduleOCRPoll() }
        }
    }

    private func scheduleOCRPoll() {
        ocrPollTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, isOpen, inOCR else { return }
            refresh()
        }
    }

    /// Tool tabs / commands. `false` = the typed text is a normal search, so refresh continues down to the core.
    private func refreshMode(_ mode: SpotlightMode) -> Bool {
        switch mode {
        case .search:
            return false
        case .commandMenu(let filter):
            // `:kill chrome` (with a space) goes straight into the command, like the legacy launcher.
            if let trigger = SpotlightCommands.inlineTrigger(filter) {
                enterCommand(trigger.id, args: trigger.args)
            } else {
                publish(SpotlightModeRows.commandMenu(filter))
            }
        case .clipboard(let term):
            searchClipboard(term)
        case .lookup(let word):
            publish(SpotlightModeRows.lookup(word))
        case .translate(let text):
            startTranslation(text)
        case .process(let term):
            processModel.loadSnapshotIfNeeded()
            publish(SpotlightModeRows.processes(processModel, term: term))
        }
        return true
    }

    /// Clipboard tab. A typed term is matched by the core over each clip's whole text, off
    /// the main thread (the list itself only holds previews), so it follows the same
    /// debounce / cancel pattern as the other searches and stale results never land. An
    /// empty term has nothing to look up and publishes after a task hop, which also means
    /// the store's own change (this runs from `$entries`) has finished by then.
    private func searchClipboard(_ term: String) {
        let debounce: Duration = expanded && !term.isEmpty ? SpotlightBackend.debounce : .zero
        searchTask = Task { @MainActor in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            let rows = await SpotlightModeRows.clipboardAll(clipboardStore, term: term)
            // Text changed while searching: these results are stale.
            guard !Task.isCancelled else { return }
            searchTask = nil
            publish(rows)
        }
    }

    /// tr": the target-language rows show right away; the translations fill in once typing pauses.
    /// Runs as `searchTask`, so an Enter pressed meanwhile waits and copies the fresh translation.
    private func startTranslation(_ text: String) {
        let source = text.isEmpty ? nil : TextTranslator.detectLanguage(of: text, likely: TranslationLanguage.all)
        let rows = SpotlightModeRows.translation(text, source: source)
        // First keystroke (panel not expanded yet) translates immediately; further typing waits a beat.
        let debounce: Duration = expanded ? .milliseconds(200) : .zero
        // Coming from another mode: the old results belong to some earlier text.
        if all.first?.kind != .translation { translation.results = [:] }
        translation.text = text
        translation.sourceName = source.map(TextTranslator.displayName(of:))
        translation.isTranslating = !rows.isEmpty
        // Same targets as before: keep the rows (and the selection) as they are.
        if !expanded || rows.map(\.id) != all.map(\.id) { publish(rows) }
        guard !rows.isEmpty else { return }

        let targets = rows.compactMap { TranslationLanguage.named($0.payload) }
        // Already translated (reopened on the same text, or typed it again): show it now,
        // with no debounce, no "Translating…" flash and no API call.
        if let cached = TextTranslator.cachedTranslations(text, from: source, to: targets) {
            searchTask?.cancel()
            searchTask = nil
            translation.results = cached
            translation.isTranslating = false
            if activateWhenReady {
                activateWhenReady = false
                activate()
            }
            return
        }
        searchTask = Task { @MainActor in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            let results = await SpotlightModeRows.translate(text, from: source, to: targets)
            // Text changed while translating: these results are stale.
            guard !Task.isCancelled else { return }
            searchTask = nil
            translation.results = results
            translation.isTranslating = false
            if activateWhenReady {
                activateWhenReady = false
                activate()
            }
        }
    }

    private func isMode(_ kind: SpotlightKind) -> Bool {
        activeCommand == nil && scope == nil && browse == kind
    }

    /// Enters a command (`:kill`, `:emptytrash`, `:help`). The text after the command name becomes its argument.
    private func enterCommand(_ id: String, args: String = "") {
        scopeReturnQuery = ""
        withAnimation(motion(SpotlightMotion.chip)) {
            scope = nil
            browse = nil
            activeCommand = id
            query = args
        }
        lastCommand = id
        switch id {
        case SpotlightCommands.kill: processModel.refreshSnapshot()
        case SpotlightCommands.emptyTrash: trashCount = TrashService.itemCount()
        default: break
        }
        focusField()
    }

    /// ⌘/ — like the legacy launcher: reopen the most recent command, or exit the open one.
    private func toggleCommandMode() {
        if activeCommand != nil { exitChip() } else { enterCommand(lastCommand) }
    }

    /// :kill — the first Enter only selects (so a slip doesn't kill the wrong thing), the second one kills.
    private func confirmKill(_ item: SpotlightItem) {
        guard let pid = item.pid else { return }
        if armedKillPID == pid {
            armedKillPID = nil
            killProcess(item)
        } else {
            armedKillPID = pid
            toast("⏎ again to force quit \(item.name)")
        }
    }

    private func killProcess(_ item: SpotlightItem) {
        guard let pid = item.pid else { return }
        switch processModel.kill(pid: pid) {
        case .success:
            toast("Force quit \(item.name)")
        case .failure(let error):
            toast("Couldn't quit \(item.name): \(error.message)")
        }
    }

    /// Destructive actions run on the second Enter (same key) so a slip doesn't delete anything.
    private func confirm(_ key: String, prompt: String, perform: () -> Void) {
        if armedConfirm == key {
            armedConfirm = nil
            perform()
        } else {
            armedConfirm = key
            toast(prompt)
        }
    }

    /// Actions that need launcher state (confirmation, async tool run). `false` = not one of them.
    private func performLocal(_ action: SpotlightAction, on item: SpotlightItem) -> Bool {
        switch action {
        case .openInEditor:
            runTool(AppConstants.Launcher.Tools.editAction, on: item)
        case .openInTerminal:
            runTool(AppConstants.Launcher.Tools.terminalAction, on: item)
        case .moveToTrash:
            guard let path = item.target else { return true }
            confirm("trash|\(path)", prompt: "⏎ again to move \(item.name) to the Trash") {
                moveToTrash(item, path: path)
            }
        case .emptyTrash:
            confirm("emptytrash", prompt: "⏎ again to empty the Trash — this can't be undone") {
                emptyTrash()
            }
        case .excludeApp:
            confirm("exclude|\(item.id)", prompt: "⏎ again to hide \(item.name) from results") {
                excludeApp(item)
            }
        default:
            return false
        }
        return true
    }

    /// ⌘E / ⌘T / ⌘D / ⌘⇧H on the selected row (or the item whose actions are open).
    private func performShortcut(_ action: SpotlightAction) {
        guard let item = previewItem else { return }
        let allowed: Bool = switch action {
        case .openInEditor, .openInTerminal: item.isFileTarget
        case .moveToTrash, .emptyTrash: SpotlightBackend.trashAction(for: item) == action
        case .excludeApp: item.kind == .app && item.target != nil
        default: false
        }
        guard allowed else {
            toast(action == .excludeApp ? "Select an app to hide" : "Not available for \(item.name)")
            return
        }
        _ = performLocal(action, on: item)
    }

    private func runTool(_ action: String, on item: SpotlightItem) {
        guard item.isFileTarget, let path = item.target else {
            toast("Select a file or folder")
            return
        }
        let candidateID = item.candidateID ?? item.id
        let isDirectory = item.kind == .folder
        Task { @MainActor in
            switch await ToolLauncher.run(
                action, candidateID: candidateID, title: item.name, path: path, isDirectory: isDirectory
            ) {
            case .launched: hide(restore: false, launched: true)
            case .message(let text): toast(text)
            }
        }
    }

    private func moveToTrash(_ item: SpotlightItem, path: String) {
        Task { @MainActor in
            if let error = await TrashService.moveToTrash(path) {
                toast("Couldn't trash \(item.name): \(error)")
                return
            }
            toast("Moved \(item.name) to Trash")
            Task.detached(priority: .utility) { _ = EngineBridge.shared.requestIndexRefresh() }
            if scope?.id == item.id { exitChip() }
            all.removeAll { $0.id == item.id }
            sel = min(sel, max(results.count - 1, 0))
        }
    }

    private func emptyTrash() {
        Task { @MainActor in
            if let error = await TrashService.emptyTrash() {
                toast(error)
                return
            }
            toast("Trash emptied")
            if activeCommand == SpotlightCommands.emptyTrash { exitChip() }
        }
    }

    private func excludeApp(_ item: SpotlightItem) {
        switch AppExcludeWriter.append(item.name) {
        case .writeFailed:
            toast("Couldn't update the config file")
        case .alreadyExcluded:
            toast("\(item.name) is already hidden")
        case .added:
            if scope?.id == item.id { exitChip() }
            // The reload re-walks the index (seconds): never on the main thread.
            Task { @MainActor in
                let ok = await EngineBridge.shared.reloadConfigInBackground()
                guard isOpen, !dismissing else { return }
                toast(ok ? "Hid \(item.name) from results" : "Saved, but reloading the config failed")
                refresh()
            }
        }
    }

    /// ⌘⇧; / the Settings button: re-read the config file.
    private func reloadConfig() {
        let result = ThemeStore.shared.reloadFromConfig()
        clipboardStore.reloadFromConfig()
        loadRetention()
        ContentIndex.shared.reloadConfig()
        SearchTags.reload()
        FileManagerApp.reload()
        suggestionsEnabled = RecentItems.isEnabled
        webSuggestMode = WebSuggestions.mode
        ExternalDrives.isEnabled = LauncherConfigFile.value(ExternalDrives.configKey).map {
            !["false", "0", "no", "off"].contains($0.lowercased())
        } ?? true
        // The core re-walks every indexed folder here (seconds). On the main thread that froze
        // the whole app, and every Settings toggle triggers it. Searches keep using the
        // previous index meanwhile.
        Task { @MainActor in
            let backendReloaded = await EngineBridge.shared.reloadConfigInBackground()
            guard isOpen, !dismissing else { return }
            if !backendReloaded {
                toast("Config reload failed")
            } else if !result.warnings.isEmpty {
                toast(result.warnings.joined(separator: ", "))
            } else {
                toast("Config reloaded")
            }
            refresh()
        }
    }

    private func loadRetention() {
        guard let raw = try? String(contentsOfFile: ConfigPathResolver.resolvedPath(), encoding: .utf8) else {
            retentionSeconds = AppConstants.Launcher.QueryRetention.defaultSeconds
            return
        }
        retentionSeconds = QueryRetentionPolicy.resolveSeconds(from: ConfigFileLines.keyValues(raw))
    }

    /// `lumio clipboard` (and other launch modes): open straight into that query.
    private func applyLaunchQuery(_ text: String) {
        show()
        let launch = SpotlightMode.tab(fromLaunchQuery: text)
        openTab(launch.tab, text: launch.text)
    }

    /// A tab's global shortcut (Settings ▸ Shortcuts): open the launcher straight on that tab, or
    /// close it when that tab is already in front. Dictionary / Translate start from the text
    /// selected in the app in front, like Option+Space does.
    private func openFromHotKey(_ tab: SpotlightKind) {
        if isOpen, !dismissing, NSApp.isActive, browse == tab, scope == nil, activeCommand == nil {
            hide()
            return
        }
        let wantsSelection = tab == .lookup || tab == .translation
        if !wantsSelection { selectionTask?.cancel() }
        let read = wantsSelection ? startSelectionRead() : nil
        show()
        openTab(tab, text: "")
        if let read { applySelection(read) { text in query = text } }
    }

    /// A tag's global shortcut (Settings ▸ Shortcuts): open the launcher already inside that
    /// tag, or close it when that tag is what is showing. `browse` opens the tag browser.
    private func openTagFromHotKey(_ keyword: String) {
        let wantsBrowser = keyword == "browse"
        let showing = wantsBrowser ? activeCommand == Self.tagsCommand : tagStack.map(\.keyword) == [keyword]
        if isOpen, !dismissing, NSApp.isActive, showing, scope == nil {
            hide()
            return
        }
        // A hotkey asks for this tag: don't bring back the search from last time.
        keptQuery = ""
        keptTags = []
        keptBrowse = nil
        show()
        if wantsBrowser {
            openTagBrowser()
            return
        }
        guard let found = SearchTags.tag(forKeyword: keyword) else {
            toast("There is no tag named \(keyword)")
            return
        }
        withAnimation(motion(SpotlightMotion.chip)) {
            scope = nil
            activeCommand = nil
            browse = nil
            filter = nil
            tagStack = [found]
        }
        query = ""
        focusField()
    }

    /// ⌥T: every search tag in one list; type to filter, ⏎ or ⇥ to use one.
    private func openTagBrowser() {
        withAnimation(motion(SpotlightMotion.chip)) { tagStack = [] }
        enterCommand(Self.tagsCommand)
    }

    private func setSort(_ mode: ResultSort) {
        sortMode = mode
        sel = 0
        toast(mode == .relevance ? "Default order" : "Sorted by \(mode.label.lowercased())")
    }

    /// The footer's sort button: Fluent Search's "Sort by" menu.
    private func showSortMenu() {
        let menu = NSMenu()
        for mode in ResultSort.allCases {
            let entry = MenuActionTarget.item(mode.label) { setSort(mode) }
            entry.state = mode == sortMode ? .on : .off
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Apps that can be uninstalled by moving them to the Trash: in an Applications folder,
    /// not part of macOS, and not Lumio itself.
    /// Shows the results. Expands the panel if it isn't already.
    private func publish(_ rows: [SpotlightItem]) {
        // The first results after the panel opens rise in one by one (SpotlightRiseIn). Later
        // ones, while typing, swap with a short spring: rows that stay slide to their new place,
        // new rows fade in, dropped rows vanish. Swapping instantly made the list flicker.
        var swap = Transaction()
        if expanded, !introActive, !reduceMotion {
            swap.animation = SpotlightMotion.typingSwap
        } else {
            swap.disablesAnimations = true
        }
        withTransaction(swap) {
            all = rows
            shownQuery = query
            sel = keepSelOnPublish.map { min($0, max(0, rows.count - 1)) } ?? 0
        }
        if !expanded { setExpanded(true) }
        if activateWhenReady {
            activateWhenReady = false
            activate()
        }
    }

    private func setExpanded(_ open: Bool) {
        if open {
            // The 4 round buttons are still merging into the bar: wait for the bar to grow before dropping
            // the panel, so results fall straight down instead of sweeping diagonally.
            let sinceMerge = Date().timeIntervalSince(mergeStartedAt)
            let delay = reduceMotion ? 0 : max(0, SpotlightMotion.expandAfterMerge - sinceMerge)
            resizeDelay = delay
            introUntil = Date().addingTimeInterval(SpotlightMotion.introWindow + delay)
        }
        withAnimation(motion(SpotlightMotion.resize)) { expanded = open }
    }

    /// After the field is empty for a while the 4 round buttons split off; with content they merge back.
    private func pokeIdle() {
        idleTask?.cancel()
        // Suggestions fill the empty field instead of the round buttons (Fluent-style).
        let canIdle = isOpen && !dismissing && query.isEmpty && scope == nil && browse == nil
            && activeCommand == nil && tag == nil && !suggestionsEnabled
        guard canIdle else {
            if idle {
                mergeStartedAt = Date()
                withAnimation(motion(SpotlightMotion.merge)) { idle = false }
            }
            return
        }
        guard !idle else { return }
        idleTask = Task { @MainActor in
            try? await Task.sleep(for: SpotlightMotion.idleDelay)
            guard !Task.isCancelled, isOpen, !dismissing,
                  query.isEmpty, scope == nil, browse == nil, activeCommand == nil, tag == nil,
                  !suggestionsEnabled
            else { return }
            withAnimation(motion(SpotlightMotion.morph)) { idle = true }
        }
    }

    private func move(_ delta: Int) {
        guard expanded, !results.isEmpty else { return }
        // The selection bar SLIDES to the new row (like the legacy launcher) instead of jumping.
        let next = (sel + delta + results.count) % results.count
        let wrapped = abs(next - sel) > 1
        withAnimation(motion(SpotlightMotion.selectionGlide)) { sel = next }
        scrollWraps = wrapped
        scrollTarget = results[sel].id
        scheduleClipPreview()
    }

    /// Enter.
    private func activate() {
        // Idle with a round button focused by Tab: open that one.
        if idle, let index = quickFocus, Self.quickItems.indices.contains(index) {
            quickFocus = nil
            toggleBrowse(Self.quickItems[index].kind)
            return
        }
        // Results for the latest text haven't arrived: wait, then open, so we don't open a stale row.
        if searchTask != nil {
            activateWhenReady = true
            return
        }
        guard expanded, sel < results.count else { return }
        run(results[sel])
    }

    /// Enter on a clip: its text is in the database, not in the row, so it is loaded first
    /// (off the main thread) and written to the pasteboard once it arrives.
    private func copyClip(_ item: SpotlightItem) {
        guard let id = item.clipID else { toast("Nothing to copy"); return }
        Task { @MainActor in
            guard let text = await clipboardStore.content(of: id) else {
                toast("Nothing to copy")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hide()
        }
    }

    /// Opens a row (or runs its action when in actions mode).
    private func run(_ item: SpotlightItem) {
        if item.id == SpotlightBackend.lumioSettingsID {
            openSettings()
            return
        }
        if item.id == Self.windowsBlockedRow {
            // Says whether the permission is off or stale, and offers the fix that fits.
            hide(restore: false)
            AccessibilityDoctor.shared.showStatus()
            return
        }
        if item.id.hasPrefix(SystemCommands.idPrefix), let id = item.payload {
            if id == SystemCommands.emptyTrash {
                enterCommand(SpotlightCommands.emptyTrash)
            } else if let problem = SystemCommands.run(id) {
                toast(problem)
            } else {
                hide(restore: false)
            }
            return
        }
        if item.id.hasPrefix(SystemCommands.runPrefix) {
            if let problem = SystemCommands.runInTerminal(item.payload ?? "") {
                toast(problem)
            } else {
                hide(restore: false, launched: true)
            }
            return
        }
        if item.kind == .window {
            if OpenWindows.shared.activate(id: item.id) {
                hide(restore: false, launched: true)
            } else {
                toast("That window is no longer open")
                all.removeAll { $0.id == item.id }
            }
            return
        }
        if item.kind == .tagHint, activeCommand == Self.tagsCommand {
            // Picked in the tag browser: leave the browser and lock the tag.
            guard let picked = item.payload.flatMap(SearchTags.tag(forKeyword:)) else { return }
            if let raw = picked.mode, let kind = SpotlightKind(rawValue: raw) {
                openTab(kind, text: "")
            } else {
                withAnimation(motion(SpotlightMotion.chip)) { activeCommand = nil }
                lockTag(picked, rest: "")
            }
            return
        }
        switch item.kind {
        case .prefix:
            // Like the legacy launcher: picking a prefix fills it into the field, then you type the keyword.
            query = item.payload ?? ""
            focusField()
            return
        case .command:
            if item.payload == SpotlightCommands.emptyTrash, activeCommand == SpotlightCommands.emptyTrash {
                confirm("emptytrash", prompt: "⏎ again to empty the Trash — this can't be undone") {
                    emptyTrash()
                }
            } else if let id = item.payload {
                enterCommand(id)
            }
            return
        case .help:
            return
        case .tagHint:
            _ = enterTag(keyword: item.payload)
            return
        case .content where item.target == nil:
            // OCR tab status row: nothing to open.
            return
        case .clipImage:
            if let hash = item.payload,
               let entry = clipboardStore.imageEntries.first(where: { $0.id == hash }),
               clipboardStore.copyImage(entry: entry)
            {
                hide()
            } else {
                toast("Couldn't copy image")
            }
            return
        case .clip:
            copyClip(item)
            return
        case .lookup:
            return  // definitions are already shown in the right half
        case .translation:
            if let text = translation.result(for: item.payload)?.text {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                toast("Copied translation")
            } else {
                toast("Nothing to copy")
            }
            return
        case .process:
            guard let pid = item.pid else { return }
            if activeCommand == SpotlightCommands.kill {
                confirmKill(item)
            } else {
                processModel.measureCPU(pid: pid)  // ps": Enter measures CPU, like the legacy launcher
            }
            return
        default:
            break
        }
        if let action = item.action, let scope, scope.kind == .process {
            switch action {
            case .measureCPU:
                if let pid = scope.pid { processModel.measureCPU(pid: pid) }
            case .killProcess:
                killProcess(scope)
                exitChip()
            case .copyPID:
                if let pid = scope.pid {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(pid), forType: .string)
                    toast("Copied PID \(pid)")
                }
            default:
                break
            }
            return
        }
        if let action = item.action, let scope, performLocal(action, on: scope) {
            return
        }
        let outcome = if let action = item.action, let scope {
            SpotlightOpener.perform(action, on: scope)
        } else {
            SpotlightOpener.open(item)
        }
        switch outcome {
        case .launched:
            // Learn the pick for this text (normal searches only): it comes first next time.
            if item.action == nil, tag == nil, browse == nil {
                UsageLearning.shared.record(item, query: query)
            }
            // The just-opened app comes to the front by itself: don't return focus to the previous app.
            hide(restore: false, launched: true)
        case .message(let text):
            toast(text)
        }
    }

    /// ⌘K: view the actions of the selected row.
    private func enterScope() {
        guard scope == nil, sel < results.count else { return }
        let item = results[sel]
        guard item.supportsActions else { return }
        scopeReturnQuery = query
        withAnimation(motion(SpotlightMotion.chip)) {
            scope = item
            query = ""
        }
        focusField()
    }

    private func toggleBrowse(_ kind: SpotlightKind) {
        withAnimation(motion(SpotlightMotion.chip)) {
            scope = nil
            browse = (browse == kind) ? nil : kind
            if browse != nil { tagStack = [] }  // a Lumio tab replaces a search tag chip
        }
        focusField()
    }

    /// Remove the chip: exit actions (restoring the typed text) or exit the browsed group.
    private func exitChip() {
        withAnimation(motion(SpotlightMotion.chip)) {
            if scope != nil {
                scope = nil
                query = scopeReturnQuery
                scopeReturnQuery = ""
            } else if activeCommand != nil {
                activeCommand = nil
                query = ""
            } else if !tagStack.isEmpty {
                // ⌫ removes the last tag only (`downloads` `.pdf` → `downloads`).
                tagStack.removeLast()
                query = ""
            } else {
                browse = nil
            }
        }
    }

    /// Escape always closes the launcher, even inside a mode (Clipboard, Dictionary, …).
    /// ⌫ on an empty field still leaves the mode without closing.
    private func handleEscape() {
        // Esc first drops the Tab focus on a round button, then closes.
        if quickFocus != nil {
            quickFocus = nil
            return
        }
        hide()
    }

    /// ⌫ on an empty field: remove the scope chip. Returns `false` so the key goes back to the field.
    private func handleDelete() -> Bool {
        guard query.isEmpty, browse != nil || scope != nil || activeCommand != nil || tag != nil else { return false }
        exitChip()
        return true
    }

    /// Keys while the Quick Look panel is key: ⌘Y / Space close it, ↑ / ↓ move the
    /// launcher's selection and Quick Look follows (like Finder). The rest is Quick Look's.
    private func handleQuickLookKey(_ event: NSEvent) -> Bool {
        typealias KeyCode = AppConstants.Launcher.KeyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shiftReturn = flags == .shift
            && (event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter)
        if SpotlightQuickLook.matchesShortcut(event) || (flags.isEmpty && key == " ") || shiftReturn {
            SpotlightQuickLook.close()
            return true
        }
        if flags.isEmpty, event.keyCode == KeyCode.arrowUp || event.keyCode == KeyCode.arrowDown {
            move(event.keyCode == KeyCode.arrowUp ? -1 : 1)
            if sel < results.count { SpotlightQuickLook.follow(item: results[sel]) }
            return true
        }
        return false
    }

    /// Navigation keys, called from SpotlightKeyMonitor. `true` = handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        typealias KeyCode = AppConstants.Launcher.KeyCode
        if isOpen, !dismissing, event.window is QLPreviewPanel {
            return handleQuickLookKey(event)
        }
        guard isOpen, !dismissing, event.window is LauncherPanelWindow else { return false }
        // The input method has uncommitted text: the key belongs to the input method.
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case KeyCode.escape:
            handleEscape()
            return true
        case KeyCode.arrowUp where !flags.contains(.shift):
            move(-1)
            return true
        case KeyCode.arrowDown where !flags.contains(.shift):
            move(1)
            return true
        case KeyCode.tab where activeCommand == Self.tagsCommand:
            // Tag browser: Tab picks the selected tag, like ⏎.
            if sel < results.count { run(results[sel]) }
            return true
        case KeyCode.tab:
            // `yt` + Tab → YouTube search tag. Otherwise Tab cycles the filter pills as before.
            if !flags.contains(.shift), enterTag() { return true }
            // Idle (the round buttons are out): Tab walks field → buttons → field, Enter opens one.
            if idle, query.isEmpty {
                let stops = Self.quickItems.count + 1  // + the field itself
                let current = quickFocus.map { $0 + 1 } ?? 0
                let next = (current + (flags.contains(.shift) ? -1 : 1) + stops) % stops
                quickFocus = next == 0 ? nil : next - 1
                return true
            }
            cycleFilter(flags.contains(.shift) ? -1 : 1)
            return true
        case Self.backspaceKeyCode where flags.isEmpty:
            return handleDelete()
        default:
            break
        }

        if flags == .control, key == "n" || key == "p" {
            move(key == "n" ? 1 : -1)
            return true
        }
        // ⇧⏎: the separate preview window (Fluent's Shift+Return); the same key closes it.
        if flags == .shift, event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter {
            if let item = previewItem { SpotlightQuickLook.toggle(item: item) }
            return true
        }
        // ⌥S: next sort order (Default → Name → Date modified → File size → Type).
        if flags == .option, event.keyCode == 1 {
            let modes = ResultSort.allCases
            setSort(modes[((modes.firstIndex(of: sortMode) ?? 0) + 1) % modes.count])
            return true
        }
        // ⌥T: browse every search tag (Fluent's Alt+T).
        if flags == .option, event.keyCode == 17 {
            if activeCommand == Self.tagsCommand { exitChip() } else { openTagBrowser() }
            return true
        }
        // ⌘K / ⌃K — view the actions of the selected row (Tab now cycles the filter pills).
        if flags == .command || flags == .control, key == "k" {
            enterScope()
            return true
        }
        // ⌥P: details card ↔ preview for the selected file or folder (Fluent's Alt+P).
        if flags == .option, event.keyCode == 35, let item = previewItem {
            togglePreview(for: item)
            return true
        }
        // ⌘⇧P: pin / unpin the selected result to Home.
        if flags == [.command, .shift], key == "p", let item = previewItem {
            toggleHomePin(item)
            return true
        }
        // ⌘R: Search in Parent Folder (a folder: search inside it).
        if flags == .command, key == "r", let item = previewItem, item.isFileTarget, let path = item.target {
            lockTag(.folder(item.kind == .folder ? path : (path as NSString).deletingLastPathComponent), rest: "")
            return true
        }
        // ⌘⇧C: copy the selected result's path or link.
        if flags == [.command, .shift], key == "c", let item = previewItem,
           let text = item.tab?.url ?? item.target
        {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            toast(text.hasPrefix("/") ? "Copied path" : "Copied link")
            return true
        }
        if flags == .command, key == "/" {
            toggleCommandMode()
            return true
        }
        if flags == .command, key == "h" {
            enterCommand(SpotlightCommands.help)
            return true
        }
        if flags == [.command, .shift], key == "h" {
            performShortcut(.excludeApp)
            return true
        }
        if flags == .command, key == "e" || key == "t" {
            performShortcut(key == "e" ? .openInEditor : .openInTerminal)
            return true
        }
        if flags == .command, key == "d", let item = previewItem {
            // Clipboard rows: ⌘D removes the clip from history instead.
            if !deleteClip(item) {
                performShortcut(SpotlightBackend.trashAction(for: item) ?? .moveToTrash)
            }
            return true
        }
        // Quick Look the selected row, like Finder (⌘Y unless changed in Settings ▸ Shortcuts).
        if SpotlightQuickLook.matchesShortcut(event) {
            if let item = previewItem { SpotlightQuickLook.toggle(item: item) }
            return true
        }
        if flags == .command, key == "p", let item = previewItem,
           item.kind == .clip || item.kind == .clipImage
        {
            togglePin(item)
            return true
        }
        // ⌘↩ — search the web for the typed text (like the legacy launcher).
        if flags == .command, event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return true }
            run(SpotlightItem(id: "web|\(term)", name: term, kind: .web))
            return true
        }
        // ⌘F — show the selected item in Finder (like the legacy launcher).
        if flags == .command, key == "f", let item = previewItem,
           item.target?.hasPrefix("/") == true, item.kind != .clipImage
        {
            switch SpotlightOpener.perform(.reveal, on: item) {
            case .launched: hide(restore: false, launched: true)
            case .message(let text): toast(text)
            }
            return true
        }
        if flags == .command, let digit = Int(key) {
            // Inside a command / command menu: ⌘N picks the Nth command, like the legacy launcher.
            let commands = SpotlightCommands.catalog
            var inCommands = activeCommand != nil
            if case .commandMenu = SpotlightMode.parse(query) { inCommands = true }
            if inCommands, commands.indices.contains(digit - 1) {
                enterCommand(commands[digit - 1].id)
                return true
            }
            if Self.quickItems.indices.contains(digit - 1) {
                toggleBrowse(Self.quickItems[digit - 1].kind)
                return true
            }
        }
        return false
    }

    private static let backspaceKeyCode: UInt16 = 51

    /// Whether the click point (in root coordinates) is on the glass cluster.
    private func clusterContains(_ point: CGPoint) -> Bool {
        let quicks = idle
            ? CGFloat(Metric.quickCount) * (Metric.quickSize + Metric.quickGap)
            : 0
        let rect = CGRect(
            x: SpotlightWindowSizing.margin,
            y: SpotlightWindowSizing.margin,
            width: panelWidth + quicks,
            height: panelHeight
        )
        return rect.contains(point)
    }

    /// Back to a brand-new state, no animation (the window is already hidden).
    private func resetState() {
        var plain = Transaction()
        plain.disablesAnimations = true
        withTransaction(plain) {
            idleTask?.cancel()
            toastTask?.cancel()
            searchTask?.cancel()
            searchTask = nil
            activateWhenReady = false
            query = ""
            shownQuery = ""
            all = []
            sel = 0
            filter = nil
            sortMode = .relevance
            ResultSort.forget()
            scope = nil
            scopeReturnQuery = ""
            browse = nil
            tagStack = []
            showingSuggestions = false
            expanded = false
            idle = false
            quickFocus = nil
            launching = false
            toastMsg = nil
            resizeDelay = 0
            activeCommand = nil
            armedKillPID = nil
            armedConfirm = nil
            trashCount = nil
            translation = SpotlightTranslationBatch()
            panelHeight = Metric.barHeight
            closeClipPreview()
            hoveredRow = nil
        }
    }

    // MARK: - Window

    private func launcherWindow() -> NSWindow? {
        NSApp.windows.first { $0 is LauncherPanelWindow }
    }

    private func toggle() {
        if isOpen, !dismissing, NSApp.isActive {
            hide()
            return
        }
        // Text selected in the app in front: open straight on its lookup (tw"). The read must
        // target the app that is in front BEFORE Lumio takes focus, so its pid is captured and
        // the read starts first; the (slow) Accessibility IPC then runs off the main thread
        // while the launcher appears, and the result is applied only if nothing changed.
        let read = startSelectionRead()
        show()
        if let read {
            applySelection(read) { text in openTab(.lookup, text: text) }
        }
    }

    /// Starts reading the selection of the frontmost app (not Lumio) on a background thread.
    /// nil when there is no other frontmost app.
    private func startSelectionRead() -> Task<String?, Never>? {
        selectionTask?.cancel()
        selectionTask = nil
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let pid = front.processIdentifier
        return Task.detached(priority: .userInitiated) {
            SelectedTextReader.selection(pid: pid)
        }
    }

    /// Waits for `read` and, if the launcher is still open exactly as `show()` left it (no
    /// typing, no other tab, not closed or reopened since), hands the text to `apply`.
    private func applySelection(_ read: Task<String?, Never>, apply: @escaping @MainActor (String) -> Void) {
        let guardrail = SelectionApplyGuard(queryAtShow: query, browseAtShow: browse)
        selectionTask = Task { @MainActor in
            guard let text = await read.value, !Task.isCancelled,
                  guardrail.shouldApply(
                      isOpen: isOpen, dismissing: dismissing, query: query, browse: browse,
                      inScope: scope != nil, hasActiveCommand: activeCommand != nil)
            else { return }
            apply(text)
        }
    }

    private func show() {
        guard let window = launcherWindow() else { return }
        // Reopened mid-close: reverse from where it is, don't rebuild.
        let reentering = dismissing
        dismissTask?.cancel()
        dismissTask = nil
        dismissing = false
        hiddenTrim.cancel()

        if pidToRestore == nil,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            pidToRestore = front.processIdentifier
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        if isOpen, !reentering {
            // Already open (e.g. an echo from applicationDidBecomeActive): just refocus.
            window.makeKeyAndOrderFront(nil)
            focusField()
            return
        }

        isOpen = true
        if !reentering {
            // Like the legacy launcher: each open asks the core to refresh the index in the background
            // (the first time it also loads the engine from SQLite) — run in the background so animation isn't delayed.
            Task.detached(priority: .utility) { _ = EngineBridge.shared.requestIndexRefresh() }
            // Snapshot the open browser tabs now, so they're ready by the first keystroke.
            BrowserTabs.shared.refresh {
                if isOpen, !dismissing, tag != nil || !query.isEmpty { refresh() }
            }
            // Open windows of other apps, for window rows and the `windows` tag.
            OpenWindows.shared.refresh {
                if isOpen, !dismissing, tag?.windows == true { refresh() }
            }
            // The permission worked and macOS now says no: find out whether it went stale.
            AccessibilityDoctor.shared.noticeIfLost()
            SpotlightFiles.setLowPriority(fromConfig: LauncherConfigFile.value(SpotlightFiles.lowPriorityConfigKey))
            SpotlightBackend.setExtraWebRows(fromConfig: LauncherConfigFile.value(SpotlightBackend.extraWebRowsKey))
            suggestionsEnabled = RecentItems.isEnabled
            webSuggestMode = WebSuggestions.mode
            ExternalDrives.isEnabled = LauncherConfigFile.value(ExternalDrives.configKey).map {
                !["false", "0", "no", "off"].contains($0.lowercased())
            } ?? true
            // Exchange rates for currency conversion: at most twice a day, in the background.
            CurrencyRates.shared.refreshIfStale()
            // Which apps are running, for the dot on their rows.
            runningApps = Set(NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
            // Pick up new bookmark folders / browser search engines: read off the main thread,
            // so the first keystroke never waits on the browsers' files.
            Task.detached(priority: .utility) {
                BrowserKeywords.warm()
                BrowserBookmarks.warm()
                await MainActor.run { SearchTags.reload() }
            }
            // While open, poll the clipboard more often (like the legacy launcher).
            clipboardStore.setMonitoringMode(.foreground)
            // Fresh open: go to the hidden state WITHOUT animation, position the window, and only then
            // animate on the next tick — the two states must be in two transactions.
            resetState()
            // Bring back the search from last time (sets the query after the reset, so it re-runs).
            // A plain search is dropped after `query_retention_seconds`; a tab (Dictionary,
            // Translate, …) always comes back as it was left.
            if keptBrowse == nil,
               QueryRetentionPolicy.shouldClear(hiddenAt: hiddenAt, seconds: retentionSeconds) {
                keptQuery = ""
                keptTags = []
            }
            hiddenAt = nil
            if let tab = keptBrowse {
                browse = tab
                keptBrowse = nil
            }
            // Tags before the text, so the search that the text starts already has its scope.
            if !keptTags.isEmpty {
                tagStack = keptTags
                keptTags = []
            }
            restoredQuery = nil
            if !keptQuery.isEmpty {
                query = keptQuery
                if browse == nil { restoredQuery = keptQuery }
                keptQuery = ""
            }
            var plain = Transaction()
            plain.disablesAnimations = true
            withTransaction(plain) {
                shownScale = false
                shownAlpha = false
            }
            let screen = SpotlightWindowSizing.screenForCursor() ?? window.screen ?? NSScreen.main
            if let screen {
                window.setFrame(SpotlightWindowSizing.frame(on: screen), display: false)
            }
            mouseGate.reset()
        }
        window.hasShadow = false
        window.makeKeyAndOrderFront(nil)
        focusField()

        DispatchQueue.main.async {
            withAnimation(motion(SpotlightMotion.appear)) {
                shownScale = true
                launching = false
            }
            withAnimation(motion(SpotlightMotion.appearFade)) { shownAlpha = true }
            pokeIdle()
            // Empty field on open: show the suggestions.
            // A restored tag with no text: list what is in the tag again.
            if !reentering, query.isEmpty, browse == nil, suggestionsEnabled || tag != nil { refresh() }
        }
    }

    /// `launched`: closing because an item was just opened (slight zoom + dissolve) instead of collapsing.
    private func hide(restore: Bool = true, launched: Bool = false) {
        guard isOpen, !dismissing, let window = launcherWindow() else { return }
        dismissing = true
        idleTask?.cancel()
        selectionTask?.cancel()
        isFocused = false
        // Quick Look belongs to the launcher: don't leave it floating on its own.
        SpotlightQuickLook.close()

        if launched {
            withAnimation(motion(SpotlightMotion.launch)) {
                launching = true
                shownAlpha = false
            }
        } else {
            withAnimation(motion(SpotlightMotion.dismiss)) {
                shownScale = false
                shownAlpha = false
            }
        }

        // Return focus to the previous app immediately, without waiting for the fade.
        if restore, let pid = pidToRestore,
           let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated
        {
            app.activate()
        }
        pidToRestore = nil

        // Dismissed (not launched) from a plain search or a tab: remember it for the next open.
        let keepable = !launched && scope == nil && activeCommand == nil
        keptBrowse = keepable ? browse : nil
        keptQuery = keepable ? query : ""
        keptTags = keepable && browse == nil ? tagStack : []

        let seconds = launched ? SpotlightMotion.launchSeconds : SpotlightMotion.dismissSeconds
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000) + 20))
            guard !Task.isCancelled else { return }
            window.orderOut(nil)
            hiddenAt = Date()
            isOpen = false
            dismissing = false
            resetState()
            // Hidden: poll the clipboard less often; next time ps" is entered, take a fresh process snapshot.
            clipboardStore.setMonitoringMode(.background)
            processModel.invalidate()
            // Hidden: drop the caches that are only there for speed on screen, but only once
            // the launcher has stayed hidden a while (show() cancels this; the condition
            // re-checks on wake-up so a reopen can never be purged under).
            hiddenTrim.schedule(after: MemoryTrim.hiddenTrimDelay, if: { !isOpen && !dismissing }) {
                await MemoryTrim.releaseCaches()
            }
        }
    }

    private func focusField() {
        isFocused = true
        // On the first open the window hasn't become key yet: set the first responder directly and
        // retry for a few beats, like the legacy launcher's focus recovery.
        for delay in [0.0, 0.05, 0.12] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard isOpen, !dismissing, let window = launcherWindow(),
                      let field = Self.caretField(in: window.contentView)
                else { return }
                if field.currentEditor() == nil { window.makeFirstResponder(field) }
                // Last beat: the field holds the restored search by now. Select it, unless
                // the user has already typed over it.
                if delay == 0.12, let restored = restoredQuery {
                    restoredQuery = nil
                    if query == restored, field.stringValue == restored {
                        field.currentEditor()?.selectAll(nil)
                    }
                }
            }
        }
    }

    private static func caretField(in view: NSView?) -> CaretTextField? {
        guard let view else { return nil }
        if let field = view as? CaretTextField { return field }
        for child in view.subviews {
            if let field = caretField(in: child) { return field }
        }
        return nil
    }
}

// MARK: - Small effects

/// Result row rises + fades in. `animation == nil`: show immediately, no effect.
private struct SpotlightRiseIn: ViewModifier {
    let animation: Animation?
    @State private var shown: Bool

    init(animation: Animation?) {
        self.animation = animation
        _shown = State(initialValue: animation == nil)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : SpotlightMotion.rowRiseOffset)
            .scaleEffect(shown ? 1 : 0.985, anchor: .top)
            .onAppear {
                guard !shown, let animation else { return }
                DispatchQueue.main.async {
                    withAnimation(animation) { shown = true }
                }
            }
    }
}

/// Icon in a round button pops out slightly after the glass droplet.
private struct SpotlightPopIn: ViewModifier {
    let animation: Animation?
    @State private var shown: Bool

    init(animation: Animation?) {
        self.animation = animation
        _shown = State(initialValue: animation == nil)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.5)
            .onAppear {
                guard !shown, let animation else { return }
                DispatchQueue.main.async {
                    withAnimation(animation) { shown = true }
                }
            }
    }
}

/// Only let hover change the selected row when the mouse actually moves. Not
/// @Observable: a mouse position change doesn't need to redraw anything.
private final class MouseGate {
    private var last = NSEvent.mouseLocation

    func reset() { last = NSEvent.mouseLocation }

    func moved() -> Bool {
        let now = NSEvent.mouseLocation
        defer { last = now }
        return now != last
    }
}

// MARK: - Tile (gradient + glyph like .tile in the HTML)
// Shared with SpotlightField (motion lab) — so not private.

struct SpotlightTile: View {
    let item: SpotlightItem
    let size: CGFloat

    @ObservedObject private var favicons = FaviconStore.shared
    @ObservedObject private var thumbnails = ThumbnailStore.shared

    var body: some View {
        if let host = item.favicon, let icon = favicons.image(for: host) {
            // The site's own icon (YouTube, Drive…), on a soft plate so dark icons stay visible.
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(size * 0.14)
                // White plate, or a dark one under a white icon (ChatGPT), so it never vanishes.
                .background(
                    favicons.isLight(host) ? Color(white: 0.13).opacity(0.95) : Color.white.opacity(0.92),
                    in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                )
                .frame(width: size, height: size)
        } else if let path = item.target, item.kind.isDocument, ThumbnailStore.wants(path),
                  let picture = thumbnails.image(for: path)
        {
            // What the file looks like (image, video, PSD, PDF), like Finder.
            Image(nsImage: picture)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
                .frame(width: size, height: size)
                // A faint plate, so a dark or part-transparent picture still reads as a tile.
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
        } else if let image = realImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: item.kind == .clipImage ? size * 0.18 : 0, style: .continuous))
                .frame(width: size, height: size)
        } else {
            colorTile
        }
    }

    /// Real icon: app/file/folder, the process's app, thumbnail of a copied
    /// image. Cached: NSWorkspace returns a new image on every call; without caching the
    /// icon flickers on every keystroke.
    private var realImage: NSImage? {
        if item.kind == .process, let pid = item.pid {
            return RowIconCache.image(key: "pid:\(pid)") {
                RowIconCache.rasterized(LauncherProcessFeature.icon(forPID: pid), points: RowIconCache.iconPoints)
            }
        }
        if item.kind == .clipImage, let path = item.iconPath {
            return RowIconCache.thumbnail(forFile: path)
        }
        return item.iconPath.map { RowIconCache.icon(forFile: $0) }
    }

    /// Colored tile for rows with no real file (calculation, web, actions, sample data).
    private var colorTile: some View {
        let pair = item.colors.split(separator: ",").map(String.init)
        let c1 = Color(hex: pair.first ?? "#9aa2ad")
        let c2 = Color(hex: pair.dropFirst().first ?? "#5c636e")
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
            if let symbol = item.symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(item.glyph ?? String(item.name.replacingOccurrences(of: ".app", with: "").prefix(1)).uppercased())
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Hook that watches the state of the legacy launcher modes (see `modeHooks`).
private struct SpotlightModeHooks: ViewModifier {
    let activeCommand: String?
    let previewID: String?
    @ObservedObject var processModel: ProcessFinderModel
    @ObservedObject var clipboardStore: ClipboardHistoryStore
    let onCommandChange: () -> Void
    let onPreviewChange: () -> Void
    let onProcesses: () -> Void
    let onClips: () -> Void
    let onImages: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: activeCommand) { onCommandChange() }
            .onChange(of: previewID) { onPreviewChange() }
            .onReceive(processModel.$candidates) { _ in onProcesses() }
            .onReceive(clipboardStore.$entries) { _ in onClips() }
            .onReceive(clipboardStore.$imageEntries) { _ in onImages() }
    }
}

/// The rows the launcher holds, the pill filter, and what the view derives from them.
/// Derived values are refreshed when `all` or `filter` change, not on every read.
struct SpotlightResultList {
    var all: [SpotlightItem] = [] {
        didSet { derive() }
    }
    var filter: SpotlightKind? {
        didSet { if filter != oldValue { derive() } }
    }
    /// `all` narrowed to the selected pill group.
    private(set) var results: [SpotlightItem] = []
    /// Pills for the groups present in the results. OCR is not one of them: its pill is always
    /// shown (last), since it switches to a different search rather than filtering this one.
    private(set) var kinds: [SpotlightKind] = []

    /// Goes up whenever `results` changes, so a cache built from it knows when to rebuild.
    private(set) var version = 0

    private mutating func derive() {
        version &+= 1
        if let filter {
            results = all.filter { $0.kind.pillGroup == filter }
        } else {
            results = all
        }
        let modeTabs = SpotlightKind.modeTabs
        var seen: [SpotlightKind] = []
        for item in all {
            let group = item.kind.pillGroup
            if !modeTabs.contains(group), !seen.contains(group) { seen.append(group) }
        }
        kinds = seen
    }
}

/// `results` re-sorted for the sort menu (name, date, size, type). The launcher reads `results`
/// dozens of times per render, and re-sorting on each read (with a disk read per file the first
/// time) made typing lag while a sort was chosen.
final class SortedResultsMemo {
    private var version = -1
    private var mode = ResultSort.relevance
    private var rows: [SpotlightItem] = []

    func sorted(_ list: SpotlightResultList, by mode: ResultSort) -> [SpotlightItem] {
        if version == list.version, self.mode == mode { return rows }
        rows = ResultSort.sorted(list.results, by: mode)
        version = list.version
        self.mode = mode
        return rows
    }
}

/// Lets a result be dragged out of the launcher: a file / folder / app as a file (drop it into
/// Photoshop, Finder, a chat…), a link as a URL.
private struct SpotlightDragSource: ViewModifier {
    let item: SpotlightItem

    func body(content: Content) -> some View {
        if let url = Self.fileURL(item) {
            content.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL) }
        } else if let link = Self.link(item) {
            content.onDrag { NSItemProvider(object: link as NSURL) }
        } else {
            content
        }
    }

    private static func fileURL(_ item: SpotlightItem) -> URL? {
        guard [.doc, .content, .folder, .app, .clipImage].contains(item.kind),
              let path = item.target, path.hasPrefix("/")
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func link(_ item: SpotlightItem) -> URL? {
        guard [.url, .tab].contains(item.kind),
              let target = item.tab?.url ?? item.target, target.hasPrefix("http")
        else { return nil }
        return URL(string: target)
    }
}

/// A small icon button for the launcher footer, brighter under the pointer.
private struct FooterIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 22)
                .background(Color.primary.opacity(hovering ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Runs a closure when its menu item is chosen (for the Open With menu). The item keeps it
/// alive through `representedObject`.
private final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() { handler() }

    /// A menu item titled `title` that runs `handler`.
    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuActionTarget(handler: handler)
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }
}
