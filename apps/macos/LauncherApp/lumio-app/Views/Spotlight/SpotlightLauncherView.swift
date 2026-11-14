import AppKit
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

    static let quickItems: [SpotlightQuickItem] = [
        SpotlightQuickItem(kind: .app, icon: "square.grid.2x2", label: "Applications"),
        SpotlightQuickItem(kind: .folder, icon: "folder", label: "Folders"),
        SpotlightQuickItem(kind: .doc, icon: "doc.text", label: "Documents"),
        SpotlightQuickItem(kind: .content, icon: "text.viewfinder", label: "OCR"),
    ]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassSpace
    /// Selection bar that slides between rows (matchedGeometryEffect).
    @Namespace private var selectionSpace

    // Search
    @State private var query = ""
    /// Results currently shown. When the panel collapses, keep the old list so it fades
    /// out with the panel instead of vanishing first.
    @State private var all: [SpotlightItem] = []
    @State private var sel = 0
    @State private var filter: SpotlightKind?
    /// Item whose actions are being viewed (⌘K).
    @State private var scope: SpotlightItem?
    /// Query before opening actions — restored on exit.
    @State private var scopeReturnQuery = ""
    /// Text left in the field when the launcher was dismissed; restored on the next open.
    @State private var keptQuery = ""
    /// Tab (Dictionary, Translate, …) open when the launcher was dismissed; reopened with `keptQuery`.
    @State private var keptBrowse: SpotlightKind?
    @State private var browse: SpotlightKind?
    @State private var scrollTarget: String?
    /// The core search in flight (nil = results already match the input).
    @State private var searchTask: Task<Void, Never>?
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
    @State private var toastTask: Task<Void, Never>?
    @State private var pidToRestore: pid_t?
    @FocusState private var isFocused: Bool

    // MARK: - Derived

    private var results: [SpotlightItem] {
        guard let filter else { return all }
        return all.filter { $0.kind.pillGroup == filter }
    }

    /// Pills for the groups present in the results. OCR is not one of them: its pill is always
    /// shown (last), since it switches to a different search rather than filtering this one.
    private var kinds: [SpotlightKind] {
        var seen: [SpotlightKind] = []
        for item in all where !SpotlightKind.modeTabs.contains(item.kind.pillGroup) && !seen.contains(item.kind.pillGroup) {
            seen.append(item.kind.pillGroup)
        }
        return seen
    }

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

    /// Clipboard rows: a line of text, or a taller row for an image thumbnail.
    private static let clipRowHeight: CGFloat = 30
    private static let clipImageRowHeight: CGFloat = 64

    /// tw": the list is a narrow column of words, like the Dictionary.app sidebar.
    private var isLookup: Bool { all.first?.kind == .lookup }

    /// Width of the list column; the rest of the panel is the preview.
    private var listPaneWidth: CGFloat { isLookup ? 180 : 300 }

    /// Height of a word row in the tw" list (other rows use `Metric.rowHeight`).
    private static let wordRowHeight: CGFloat = 32

    /// Item shown in the preview pane: the item whose actions are being viewed, otherwise the selected row.
    private var previewItem: SpotlightItem? {
        scope ?? (sel < results.count ? results[sel] : nil)
    }

    private var targetPanelHeight: CGFloat {
        Metric.barHeight + (expanded ? SpotlightSpec.lowerHeight(rows: rowSlots) : 0)
    }

    /// Icon at the end of the bar: the item whose actions are being viewed, otherwise the top result.
    private var topHit: SpotlightItem? { scope ?? results.first }
    private var showsTopHit: Bool { expanded && topHit != nil && !isClipboard }
    private var chipLabel: String? {
        scope?.name ?? activeCommand.map { ":" + $0 } ?? browse?.label
    }

    private var placeholder: String {
        if let scope { return "Actions for \(scope.name)" }
        if let activeCommand { return SpotlightCommands.placeholder(for: activeCommand) }
        if inOCR { return "Search text in images & PDFs" }
        if let browse { return "Search in \(browse.label)" }
        return "Lumio Search"
    }

    private var introActive: Bool { !reduceMotion && Date() < introUntil }
    private var isDark: Bool { colorScheme == .dark }
    private var palette: SpotlightPalette { .of(colorScheme) }
    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metric.pillRadius, style: .continuous)
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
        .onChange(of: query) {
            sel = 0
            filter = nil
            // Typed more after Enter: that Enter belonged to the old text, drop it.
            activateWhenReady = false
            refresh()
        }
        .onChange(of: scope?.id) { refresh() }
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
            if let raw = note.object as? String, let tab = SpotlightKind(rawValue: raw) { openFromHotKey(tab) }
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
        .overlay(alignment: .topLeading) {
            topHitTile
                .frame(height: Metric.barHeight)
                .offset(x: Metric.panelWidth - Metric.barPadding - Self.topHitSize)
                .allowsHitTesting(false)
        }
        .clipShape(panelShape)
        .contentShape(panelShape)
        .spotlightGlass(panelShape, id: "spotlight.panel", in: glassSpace, isDark: isDark)
    }

    private func quickButton(_ item: SpotlightQuickItem, index: Int) -> some View {
        Button {
            toggleBrowse(item.kind)
        } label: {
            Image(systemName: item.icon)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(browse == item.kind ? HierarchicalShapeStyle.primary : .secondary)
                .modifier(SpotlightPopIn(animation: reduceMotion ? nil : motion(SpotlightMotion.quickIcon(index))))
                .frame(width: Metric.quickSize, height: Metric.quickSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .spotlightGlass(
            Circle(),
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

            // Leave room for the top-hit icon (drawn in the panel overlay) so text doesn't
            // run underneath it.
            Color.clear
                .frame(width: Self.topHitSize, height: Self.topHitSize)
        }
        .padding(.horizontal, Metric.barPadding)
        .frame(height: Metric.barHeight)
    }

    private static let topHitSize: CGFloat = 32

    /// The top result's icon pops out at the end of the bar when the panel expands.
    private var topHitTile: some View {
        ZStack {
            if let topHit {
                SpotlightTile(item: topHit, size: 30)
            }
        }
        .frame(width: Self.topHitSize, height: Self.topHitSize)
        .scaleEffect(showsTopHit || reduceMotion ? 1 : 0.6)
        .opacity(showsTopHit ? 1 : 0)
        .animation(motion(SpotlightMotion.pop), value: showsTopHit)
    }

    // MARK: - Lower part (always built; the panel clips it to the animating height)

    private var lower: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)
                .padding(.horizontal, 14)
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
            footer
                .frame(height: Metric.footerHeight)
        }
        .frame(height: SpotlightSpec.lowerHeight(rows: rowSlots), alignment: .top)
        .opacity(expanded ? 1 : 0)
        .animation(motion(expanded ? SpotlightMotion.contentIn : SpotlightMotion.contentOut), value: expanded)
        .allowsHitTesting(expanded)
    }

    /// Right half of the panel: preview of the selected row (or the item whose actions are open).
    private var previewPane: some View {
        ZStack(alignment: .topLeading) {
            if let item = previewItem, item.kind == .clip || item.kind == .clipImage {
                SpotlightClipPreview(item: item, details: clipDetails(for: item))
                    .id(item.id)
            } else if let item = previewItem {
                SpotlightPreviewView(
                    item: item,
                    processDetail: item.pid.flatMap { processModel.details[$0] },
                    processCPU: item.pid.flatMap { processModel.cpu[$0] },
                    measuringCPU: item.pid.map { processModel.measuringCPU.contains($0) } ?? false,
                    onLookup: { word in
                        openTab(.lookup, text: word)
                        focusField()
                    },
                    translation: translation
                )
                .id(item.id)
            }
        }
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
                    ForEach(SpotlightKind.modeTabs) { tab in
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

    /// Tab / Shift+Tab: move to the next / previous pill (All → Applications → … → tools → OCR → All).
    /// Landing on OCR or a tool switches to its search; leaving goes back to the name search.
    private func cycleFilter(_ step: Int) {
        let options: [SpotlightKind?] = [nil] + kinds + SpotlightKind.modeTabs.map(Optional.some)
        let current = inModeTab ? (options.firstIndex(of: browse) ?? 0) : (options.firstIndex(of: filter) ?? 0)
        let next = options[(current + step + options.count) % options.count]
        if let next, SpotlightKind.modeTabs.contains(next) {
            filter = nil
            withAnimation(motion(SpotlightMotion.chip)) { scope = nil; browse = next }
        } else {
            if inModeTab { leaveModeTab() }
            filter = next
        }
    }

    /// Opens a tool tab with some text in the field (Dictionary from a linked word, `lumio <mode>`).
    private func openTab(_ tab: SpotlightKind?, text: String) {
        withAnimation(motion(SpotlightMotion.chip)) {
            scope = nil
            activeCommand = nil
            filter = nil
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
                Text("No results for “\(query)”.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                rowView(item, selected: index == sel)
                                    .id(item.id)
                                    .modifier(SpotlightRiseIn(
                                        animation: introActive ? motion(SpotlightMotion.rowRise(index)) : nil
                                    ))
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
                        withAnimation(motion(SpotlightMotion.selectionGlide)) { proxy.scrollTo(target) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ item: SpotlightItem, selected: Bool) -> some View {
        if item.kind == .lookup {
            wordRow(item, selected: selected)
        } else if item.kind == .clip || item.kind == .clipImage {
            clipRow(item, selected: selected)
        } else if item.kind == .translation {
            standardRow(translationRow(item), selected: selected)
        } else {
            standardRow(item, selected: selected)
        }
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

    /// tw": just the word, like the Dictionary.app sidebar.
    private func wordRow(_ item: SpotlightItem, selected: Bool) -> some View {
        Text(item.name)
            .font(.system(size: 14.5, weight: selected ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: Self.wordRowHeight)
            .modifier(SpotlightSelection(
                isSelected: selected,
                fill: palette.rowSel,
                namespace: selectionSpace,
                reduceMotion: reduceMotion
            ))
            .contentShape(Rectangle())
    }

    /// Clipboard: just the copied text on one line, or a thumbnail of the image. The full text
    /// and details open in the side preview (see `scheduleClipPreview`).
    private func clipRow(_ item: SpotlightItem, selected: Bool) -> some View {
        let isImage = item.kind == .clipImage
        return Group {
            if isImage, let path = item.iconPath, let image = RowIconCache.thumbnail(forFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .frame(maxHeight: Self.clipImageRowHeight - 12)
            } else {
                Text(item.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.trailing, selected ? (item.isPinned ? 58 : 58) : (item.isPinned ? 30 : 0))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) { clipRowButtons(item, selected: selected) }
        .padding(.horizontal, 12)
        .frame(height: isImage ? Self.clipImageRowHeight : Self.clipRowHeight)
        .modifier(SpotlightSelection(
            isSelected: selected,
            fill: palette.rowSel,
            namespace: selectionSpace,
            reduceMotion: reduceMotion
        ))
        .contentShape(Rectangle())
    }

    /// Pin and delete, on the selected clip. A pinned clip always shows its pin.
    @ViewBuilder
    private func clipRowButtons(_ item: SpotlightItem, selected: Bool) -> some View {
        if selected || item.isPinned {
            HStack(spacing: 4) {
                clipIconButton(
                    item.isPinned ? "pin.fill" : "pin",
                    help: item.isPinned ? "Unpin (⌘P)" : "Pin (⌘P)",
                    active: item.isPinned
                ) { togglePin(item) }
                if selected {
                    clipIconButton("trash", help: "Delete (⌘D)") { deleteClip(item) }
                }
            }
            .padding(.leading, 6)
        }
    }

    private func clipIconButton(
        _ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background(palette.kbd, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
        if item.kind == .clip, let id = item.clipID {
            clipboardStore.deleteEntry(id: id)
            toast("Clipboard item deleted")
        } else if item.kind == .clipImage, let id = item.payload {
            clipboardStore.deleteImageEntry(id: id)
            toast("Image deleted")
        } else {
            return false
        }
        return true
    }

    private func standardRow(_ item: SpotlightItem, selected: Bool) -> some View {
        HStack(spacing: 11) {
            SpotlightRowIcon(item: item, size: 30, isSelected: selected)
            // Narrow left column (right half is the preview): name on top, path / description below.
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind == .web ? "Search the web — \(item.name)" : item.name)
                    .font(.system(size: 14.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let meta = rowMeta(item), !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            // Change IMMEDIATELY on selection: cross-fading them in step with the slide would make the
            // text of both states overlap.
            Group {
                if item.kind == .calc, let calcResult = item.calcResult {
                    Text("= \(SpotlightCalc.format(calcResult))")
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                        .fixedSize()
                } else if selected {
                    keyCap("⏎")
                } else if armedKillPID != nil, item.pid == armedKillPID {
                    keyCap("⏎")
                }
            }
            .animation(nil, value: selected)
        }
        .padding(.horizontal, 10)
        .frame(height: Metric.rowHeight)
        .modifier(SpotlightSelection(
            isSelected: selected,
            fill: palette.rowSel,
            namespace: selectionSpace,
            reduceMotion: reduceMotion
        ))
        .contentShape(Rectangle())
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
            Text(footerHint)
            Text("esc close")
            Spacer()
            if isClipboard {
                let armed = armedConfirm == "clipclear"
                Button {
                    confirm("clipclear", prompt: "Click Clear again to delete all clipboard history") {
                        clipboardStore.clearHistory()
                        toast("Clipboard cleared")
                    }
                } label: {
                    Text(armed ? "Click again to clear" : "Clear all")
                        .foregroundStyle(armed ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
            }
            if !results.isEmpty {
                Text("\(results.count) results")
            }
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
        switch activeCommand {
        case SpotlightCommands.kill: return "⏎ select, ⏎ again to force quit"
        case SpotlightCommands.emptyTrash: return "⏎ twice to empty   esc cancel"
        default: break
        }
        let mode = browse.map { SpotlightMode.forTab($0, query: query) ?? .search } ?? SpotlightMode.parse(query)
        return "↑↓ select   " + mode.footerHint
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
            default: publish([])
            }
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
            // Empty field: collapse the panel. `all` is kept so the list fades out with the panel.
            activateWhenReady = false
            if expanded { setExpanded(false) }
            return
        }

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
            let (found, recents) = await Task.detached(priority: .userInitiated) {
                let found = EngineBridge.shared.search(query: engineQuery.text, limit: engineQuery.limit)
                let recents = wantsURLs
                    ? EngineBridge.shared.recentURLs(query: urlQuery, limit: urlLimit)
                    : []
                return (found, recents)
            }.value
            // Text changed while waiting: these results are stale.
            guard !Task.isCancelled else { return }
            searchTask = nil
            publish(SpotlightBackend.rows(from: found, for: request, recentURLs: recents))
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
            publish(SpotlightModeRows.clipboardAll(clipboardStore, term: term))
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
            toast(EngineBridge.shared.reloadConfig()
                ? "Hid \(item.name) from results"
                : "Saved, but reloading the config failed")
            refresh()
        }
    }

    /// ⌘⇧; / the Settings button: re-read the config file.
    private func reloadConfig() {
        let result = ThemeStore.shared.reloadFromConfig()
        let backendReloaded = EngineBridge.shared.reloadConfig()
        clipboardStore.reloadFromConfig()
        loadRetention()
        ContentIndex.shared.reloadConfig()
        guard isOpen else { return }
        if !backendReloaded {
            toast("Config reload failed")
        } else if !result.warnings.isEmpty {
            toast(result.warnings.joined(separator: ", "))
        } else {
            toast("Config reloaded")
        }
        refresh()
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
        var text = ""
        if tab == .lookup || tab == .translation,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            text = SelectedTextReader.selection(in: front) ?? ""
        }
        show()
        openTab(tab, text: text)
    }

    /// Shows the results. Expands the panel if it isn't already.
    private func publish(_ rows: [SpotlightItem]) {
        var plain = Transaction()
        plain.disablesAnimations = true
        withTransaction(plain) {
            all = rows
            sel = 0
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
        let canIdle = isOpen && !dismissing && query.isEmpty && scope == nil && browse == nil
            && activeCommand == nil
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
                  query.isEmpty, scope == nil, browse == nil, activeCommand == nil
            else { return }
            withAnimation(motion(SpotlightMotion.morph)) { idle = true }
        }
    }

    private func move(_ delta: Int) {
        guard expanded, !results.isEmpty else { return }
        // The selection bar SLIDES to the new row (like the legacy launcher) instead of jumping.
        withAnimation(motion(SpotlightMotion.selectionGlide)) {
            sel = (sel + delta + results.count) % results.count
        }
        scrollTarget = results[sel].id
        scheduleClipPreview()
    }

    /// Enter.
    private func activate() {
        // Results for the latest text haven't arrived: wait, then open, so we don't open a stale row.
        if searchTask != nil {
            activateWhenReady = true
            return
        }
        guard expanded, sel < results.count else { return }
        run(results[sel])
    }

    /// Opens a row (or runs its action when in actions mode).
    private func run(_ item: SpotlightItem) {
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
            guard let text = item.payload else { toast("Nothing to copy"); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hide()
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
            } else {
                browse = nil
            }
        }
    }

    /// Escape always closes the launcher, even inside a mode (Clipboard, Dictionary, …).
    /// ⌫ on an empty field still leaves the mode without closing.
    private func handleEscape() {
        hide()
    }

    /// ⌫ on an empty field: remove the scope chip. Returns `false` so the key goes back to the field.
    private func handleDelete() -> Bool {
        guard query.isEmpty, browse != nil || scope != nil || activeCommand != nil else { return false }
        exitChip()
        return true
    }

    /// Navigation keys, called from SpotlightKeyMonitor. `true` = handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        typealias KeyCode = AppConstants.Launcher.KeyCode
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
        case KeyCode.tab:
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
        // ⌘K / ⌃K — view the actions of the selected row (Tab now cycles the filter pills).
        if flags == .command || flags == .control, key == "k" {
            enterScope()
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
            all = []
            sel = 0
            filter = nil
            scope = nil
            scopeReturnQuery = ""
            browse = nil
            expanded = false
            idle = false
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
        // Text selected in the app in front: open straight on its lookup (tw"). Read it
        // BEFORE Lumio takes focus.
        var selection: String?
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            selection = SelectedTextReader.selection(in: front)
        }
        show()
        if let selection {
            openTab(.lookup, text: selection)
        }
    }

    private func show() {
        guard let window = launcherWindow() else { return }
        // Reopened mid-close: reverse from where it is, don't rebuild.
        let reentering = dismissing
        dismissTask?.cancel()
        dismissTask = nil
        dismissing = false

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
            }
            hiddenAt = nil
            if let tab = keptBrowse {
                browse = tab
                keptBrowse = nil
            }
            if !keptQuery.isEmpty {
                query = keptQuery
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
        }
    }

    /// `launched`: closing because an item was just opened (slight zoom + dissolve) instead of collapsing.
    private func hide(restore: Bool = true, launched: Bool = false) {
        guard isOpen, !dismissing, let window = launcherWindow() else { return }
        dismissing = true
        idleTask?.cancel()
        isFocused = false

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
            // Hidden: drop every cache that is only there for speed on screen.
            await MemoryTrim.releaseCaches()
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

/// Background of the selected row. ONE single bar is moved between rows via
/// `matchedGeometryEffect`, so it SLIDES when the selection change happens inside
/// `withAnimation` (arrow keys, hover) and jumps straight when it doesn't (new results).
/// The newly selected row also zooms up one beat and back — same approach as the legacy launcher's
/// SelectionPill, just a different color (follows the glass, not the theme).
private struct SpotlightSelection: ViewModifier {
    let isSelected: Bool
    let fill: Color
    let namespace: Namespace.ID
    let reduceMotion: Bool

    @State private var zoomed = false
    /// Incremented on each zoom: the return leg of an old beat doesn't cut off a new one
    /// (moving away then back very quickly).
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            // Pushed down so the row's icon zooms in step.
            .environment(\.isSelectionZoomed, zoomed)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: SpotlightSpec.Metric.rowRadius, style: .continuous)
                        .fill(fill)
                        .matchedGeometryEffect(id: "spotlight.selection", in: namespace)
                        .scaleEffect(zoomed ? SpotlightMotion.pillZoomScale : 1)
                }
            }
            // No .animation(value:) here: attached per row, every row the
            // selection bar passes over would flash.
            .onChange(of: isSelected) { _, selected in
                generation &+= 1
                guard selected else {
                    zoomed = false
                    return
                }
                guard !reduceMotion else { return }
                let mine = generation
                withAnimation(SpotlightMotion.zoomIn) { zoomed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + SpotlightMotion.zoomInSeconds) {
                    guard mine == generation else { return }
                    withAnimation(SpotlightMotion.zoomOut) { zoomed = false }
                }
            }
    }
}

/// The row's icon, zooming with the selection beat. A separate view because a view can't read
/// environment values set by its own body.
private struct SpotlightRowIcon: View {
    @Environment(\.isSelectionZoomed) private var zoomed
    let item: SpotlightItem
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        SpotlightTile(item: item, size: size)
            .scaleEffect(isSelected && zoomed ? SpotlightMotion.iconZoomScale : 1)
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

    var body: some View {
        if let image = realImage {
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
            return RowIconCache.image(key: "pid:\(pid)") { LauncherProcessFeature.icon(forPID: pid) }
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

private struct SelectionZoomedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True during the one-shot zoom of the newly selected row.
    var isSelectionZoomed: Bool {
        get { self[SelectionZoomedKey.self] }
        set { self[SelectionZoomedKey.self] = newValue }
    }
}
