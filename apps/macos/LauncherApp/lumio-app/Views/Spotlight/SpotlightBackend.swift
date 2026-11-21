//
//  SpotlightBackend.swift
//  lumio-app
//
//  Connects the Spotlight launcher to the Rust core (EngineBridge → bridge/ffi → QueryEngine).
//
//  Flow of a single search:
//  1. `engineQuery(for:)` builds the query string for the core. The round buttons use the core's
//     own filter prefixes: a" (app), d" (folder), f" (file). System settings are apps with a
//     `setting:` id; they show under the Applications pill. The OCR tab skips the core and
//     searches ContentIndex (text inside images / PDFs) instead, see `contentRows`.
//  2. The view calls `EngineBridge.search` on a background thread (the core holds the engine read lock).
//  3. `rows(from:for:)` turns the core's results into display rows, then adds the
//     synthesized rows: calculation, open URL (classified by the core), search the web.
//

import AppKit

struct SpotlightRequest: Equatable {
    var text: String
    /// Browsing a single group (round button / ⌘1–4).
    var browse: SpotlightKind?

    var term: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isEmpty: Bool { term.isEmpty && browse == nil }
}

/// Query string + count sent to the core. Sendable so it can move to a background thread.
struct SpotlightEngineQuery: Sendable {
    let text: String
    let limit: Int
}

enum SpotlightBackend {
    /// Maximum number of rows shown (same as the legacy launcher).
    nonisolated static let resultLimit = 40
    /// When typing rapidly, wait a short beat; the first keystroke searches immediately.
    static let debounce: Duration = .milliseconds(45)

    private static let settingIDPrefix = "setting:"
    private static let systemSettingsAppPath = "/System/Applications/System Settings.app"

    // MARK: - Query sent to the core

    static func engineQuery(for request: SpotlightRequest) -> SpotlightEngineQuery {
        let term = request.term
        switch request.browse {
        case .app:
            return SpotlightEngineQuery(text: "a\"" + term, limit: resultLimit + 20)
        case .folder:
            return SpotlightEngineQuery(text: "d\"" + term, limit: resultLimit)
        case .doc:
            return SpotlightEngineQuery(text: "f\"" + term, limit: resultLimit)
        default:
            return SpotlightEngineQuery(text: term, limit: resultLimit)
        }
    }

    // MARK: - Core results → display rows

    static func rows(
        from results: [LauncherResult],
        for request: SpotlightRequest,
        recentURLs: [URLHistoryEntry] = [],
        tabs: [BrowserTab] = [],
        windows: [OpenWindow] = []
    ) -> [SpotlightItem] {
        // `> npm run dev`: one row, ⏎ runs it in Terminal. Nothing else is searched.
        if request.browse == nil, request.term.hasPrefix(">") {
            return [runRow(String(request.term.dropFirst()))]
        }
        // Pinned rows go on top, except below a same-named app (Music.app stays ahead of ~/Music).
        var candidates = results.compactMap(item(from:))
        for pin in pinned(for: request).reversed() {
            let rival = candidates.firstIndex { $0.kind == .app && $0.name.lowercased() == pin.name.lowercased() }
            candidates.insert(pin, at: rival.map { $0 + 1 } ?? 0)
        }
        // Code and config files sink below everything else (see SpotlightFiles.lowPriorityExtensions),
        // unless the text names an extension ("align.ts").
        if SpotlightFiles.parse(request.term).extensions.isEmpty {
            let low = candidates.filter { $0.kind == .doc && SpotlightFiles.isLowPriority($0.name) }
            if !low.isEmpty {
                candidates = candidates.filter { !($0.kind == .doc && SpotlightFiles.isLowPriority($0.name)) } + low
            }
        }
        // What you opened before for text like this goes first (see UsageLearning).
        if request.browse == nil, !hasEnginePrefix(request.term) {
            candidates.insert(contentsOf: UsageLearning.shared.picks(for: request.term, limit: 2), at: 0)
        }
        var seen = Set<String>()
        var rows: [SpotlightItem] = []
        for item in candidates {
            if let browse = request.browse, item.kind != browse { continue }
            guard seen.insert(dedupeKey(item)).inserted else { continue }
            rows.append(item)
            if rows.count == resultLimit { break }
        }

        // Synthesized rows only appear in a general search: not while browsing a group,
        // or once a core filter prefix has been typed (a" f" d").
        let term = request.term
        guard request.browse == nil, !term.isEmpty, !hasEnginePrefix(term) else { return rows }

        var leading: [SpotlightItem] = []
        if let value = SpotlightCalc.evaluate(term) {
            leading.append(SpotlightItem(
                id: "calc|\(term)", name: term, kind: .calc,
                colors: "#9aa2ad,#4d545d", calcResult: value, symbol: "equal"
            ))
        }
        // Bookmarks are already in memory, so they appear with the first results: after the
        // top local results, or right above code / config files when those are all there is.
        if term.count >= 3 {
            let marks = bookmarkRows(BrowserBookmarks.search(term, limit: 2, cachedOnly: true))
            if !marks.isEmpty {
                let firstCode = rows.firstIndex { $0.kind == .doc && SpotlightFiles.isLowPriority($0.name) }
                rows.insert(contentsOf: marks, at: min(firstCode ?? 4, 4, rows.count))
            }
        }
        // "settings", "lumio", "preferences": Lumio's own Settings window, under the best result.
        if isSettingsQuery(term) {
            rows.insert(SpotlightItem(
                id: lumioSettingsID, name: "Lumio Settings", kind: .setting,
                colors: "#9aa2ad,#5c636e", meta: "Open Lumio's settings  ·  ⌘⇧Space",
                iconPath: Bundle.main.bundlePath, symbol: "gearshape.fill"
            ), at: min(1, rows.count))
        }
        // "5 km to miles", "100 usd to gbp": units and currency (see Conversions).
        if let conversion = Conversions.evaluate(term) {
            leading.append(SpotlightItem(
                id: "convert|\(term)", name: term, kind: .calc,
                colors: "#7fe0c3,#1f9d8d", meta: conversion.detail,
                symbol: "arrow.left.arrow.right", payload: conversion.output
            ))
        }
        if let match = EngineBridge.shared.classifyURL(query: term) {
            let row = SpotlightItem(
                id: "url|\(match.url)", name: match.url, kind: .url,
                colors: "#8fb8ff,#3a6fd8", meta: "Open link",
                target: match.url, symbol: "link", favicon: FaviconStore.host(of: match.url)
            )
            // Explicit URLs (with scheme/path) go first; bare domains come
            // after the best result, like the legacy launcher (URLRowPlacement).
            if match.tier == .structural {
                leading.append(row)
            } else {
                rows.insert(row, at: min(1, rows.count))
            }
        }
        // Previously opened links matching the text, after the best result.
        let liveURL = EngineBridge.shared.classifyURL(query: term)?.url
        let recents = recentURLs.filter { $0.url != liveURL }.map { entry in
            SpotlightItem(
                id: "url|\(entry.url)", name: entry.url, kind: .url,
                colors: "#8fb8ff,#3a6fd8", meta: "Recently opened",
                target: entry.url, symbol: "clock.arrow.circlepath", favicon: FaviconStore.host(of: entry.url)
            )
        }
        rows.insert(contentsOf: recents, at: min(1, rows.count))
        // Open browser tabs matching the text: ⏎ switches to the tab instead of opening a new one.
        let openTabs = tabs.map(item(from:))
        let openURLs = Set(tabs.map(\.url))
        rows.removeAll { $0.kind == .url && openURLs.contains($0.target ?? "") }
        rows.insert(contentsOf: openTabs, at: min(1, rows.count))
        // Open windows of other apps matching the text: ⏎ switches to the window.
        rows.insert(contentsOf: windows.map(item(from:)), at: min(1, rows.count))
        // "lock", "sleep", "restart"…: system commands. An exact name leads the list.
        for command in SystemCommands.matching(term).reversed() {
            let row = systemRow(command)
            if SystemCommands.isExact(term, command) { leading.append(row) } else { rows.insert(row, at: min(1, rows.count)) }
        }
        // `yt`, `drive`…: a hint that Tab turns the text into a search tag. After the best result,
        // so typing "g" + ⏎ still opens the top app.
        let rest = SearchTags.split(term)?.rest ?? ""
        let hints = SearchTags.suggestions(for: term).map { hintItem(for: $0, rest: rest) }
        rows.insert(contentsOf: hints, at: min(1, rows.count))
        let web = SpotlightItem(
            id: "web|\(term)", name: term, kind: .web,
            colors: "#8fb8ff,#3a6fd8", meta: "Search the web", symbol: "globe", favicon: "google.com"
        )
        // More engines under "Search the web" (`web_search_rows=yt,bing`), like Fluent's rows.
        let engines = extraWebTags.compactMap { tag -> SpotlightItem? in
            guard let target = tag.url(for: term)?.absoluteString else { return nil }
            return SpotlightItem(
                id: "engine|\(tag.keyword)|\(term)", name: term, kind: .web, colors: tag.colors,
                meta: "Search \(tag.name)", target: target, symbol: tag.symbol, favicon: tag.faviconHost
            )
        }
        return leading + rows + [web] + engines
    }

    static let extraWebRowsKey = "web_search_rows"

    /// Tags named in `web_search_rows`, read on each launcher open.
    static var extraWebTags: [SearchTag] = []

    static func setExtraWebRows(fromConfig value: String?) {
        extraWebTags = (value ?? "").split(whereSeparator: { ", ;|".contains($0) })
            .compactMap { SearchTags.tag(forKeyword: String($0)) }
            .filter { $0.urlTemplate.contains("{query}") }
    }

    static func runRow(_ text: String) -> SpotlightItem {
        let command = text.trimmingCharacters(in: .whitespaces)
        return SpotlightItem(
            id: SystemCommands.runPrefix + command, name: command.isEmpty ? "Run a command in Terminal" : command,
            kind: .command, colors: "#a7aeb8,#30363d",
            meta: command.isEmpty ? "Type the command after >" : "⏎ run in Terminal",
            symbol: "terminal.fill", payload: command
        )
    }

    static func systemRow(_ command: SystemCommand) -> SpotlightItem {
        SpotlightItem(
            id: SystemCommands.idPrefix + command.id, name: command.name, kind: .command,
            colors: command.colors, meta: command.detail, symbol: command.symbol, payload: command.id
        )
    }

    static func item(from window: OpenWindow) -> SpotlightItem {
        SpotlightItem(
            id: window.id, name: window.title, kind: .window, colors: "#9aa8ff,#4a4fd6",
            meta: "\(window.appName) · \(window.minimized ? "minimized window" : "open window")",
            iconPath: window.appPath, symbol: "macwindow"
        )
    }

    /// Every tag, for the tag browser (⌥T): name, what to type, what it searches.
    static func tagBrowserRows(_ filter: String) -> [SpotlightItem] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var seen = Set<String>()
        return SearchTags.all
            .filter { seen.insert($0.name).inserted }
            .filter { needle.isEmpty || $0.keyword.contains(needle) || $0.name.lowercased().contains(needle) }
            .map { tag in
                let what = tag.files != nil ? "Files"
                    : tag.bookmarks != nil || tag.history ? "Browser"
                    : tag.mode != nil ? "Lumio tab"
                    : tag.settingsOnly ? "System Settings"
                    : tag.windows ? "Windows" : "Web search"
                return SpotlightItem(
                    id: "taghint|\(tag.keyword)", name: tag.name, kind: .tagHint, colors: tag.colors,
                    meta: "\(tag.keyword) ⇥  ·  \(what)", symbol: tag.symbol, payload: tag.keyword,
                    favicon: tag.faviconHost
                )
            }
    }

    /// One core row → display row. nil for launcher kinds not handled yet
    /// (user-declared command blocks).
    static func item(from result: LauncherResult) -> SpotlightItem? {
        let path = result.path
        switch result.kind {
        case .app where result.id.hasPrefix(settingIDPrefix):
            return SpotlightItem(
                id: result.id, name: result.title, kind: .setting,
                meta: "System Settings", target: path,
                iconPath: systemSettingsAppPath, candidateID: result.id
            )
        case .app:
            // /Applications/Safari.app… is a symlink into the system cryptex: take the icon
            // from the real path, otherwise the icon gets an alias arrow.
            let iconPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return SpotlightItem(
                id: result.id, name: displayName(forApp: result.title), kind: .app,
                target: path, iconPath: iconPath, candidateID: result.id
            )
        case .file:
            return SpotlightItem(
                id: result.id, name: result.title, kind: .doc,
                meta: PathDisplay.directory(of: path), target: path,
                iconPath: path, candidateID: result.id
            )
        case .folder:
            return SpotlightItem(
                id: result.id, name: result.title, kind: .folder,
                meta: PathDisplay.directory(of: path), target: path,
                iconPath: path, candidateID: result.id
            )
        case .action, .clipboard, .process:
            return nil
        }
    }

    /// A file matched by its content: the snippet around the match replaces the folder line.
    static func item(from hit: ContentHit) -> SpotlightItem {
        SpotlightItem(
            id: "content|" + hit.path, name: (hit.path as NSString).lastPathComponent, kind: .content,
            meta: hit.snippet ?? PathDisplay.directory(of: hit.path), target: hit.path, iconPath: hit.path
        )
    }

    static let lumioSettingsID = "lumio|settings"

    /// Typed text heading for "settings", "preferences", "lumio" or "lumio settings".
    private static func isSettingsQuery(_ term: String) -> Bool {
        let typed = term.lowercased()
        guard typed.count >= 3 else { return false }
        return ["settings", "preferences", "lumio settings", "lumio preferences", "lumio"].contains { $0.hasPrefix(typed) }
    }

    // MARK: - Browser tabs, search tags, suggestions

    nonisolated static let tabLimit = 4

    static func item(from tab: BrowserTab) -> SpotlightItem {
        SpotlightItem(
            id: tab.id, name: tab.title, kind: .tab,
            colors: "#8fb8ff,#3a6fd8", meta: "\(tab.host) · Open in \(tab.browser.displayName)",
            target: tab.url, iconPath: tab.appPath, symbol: "square.on.square",
            favicon: FaviconStore.host(of: tab.url), tab: tab
        )
    }

    /// "Press Tab" row. `rest` = the text that would be searched (`cats yt` → "cats").
    static func hintItem(for tag: SearchTag, rest: String = "") -> SpotlightItem {
        SpotlightItem(
            id: "taghint|\(tag.keyword)",
            name: rest.isEmpty ? tag.name : "\(tag.name): “\(rest)”",
            kind: .tagHint, colors: tag.colors,
            meta: rest.isEmpty ? "Press Tab to search \(tag.name)  ·  \(tag.keyword) ⇥"
                : "Press Tab to search \(tag.name) for “\(rest)”",
            symbol: tag.symbol, payload: tag.keyword, favicon: tag.faviconHost
        )
    }

    static func bookmarkRows(_ bookmarks: [Bookmark]) -> [SpotlightItem] {
        bookmarks.map { bookmark in
            SpotlightItem(
                id: "bookmark|" + bookmark.url, name: bookmark.title, kind: .url,
                colors: "#ffb36e,#f06a2e", meta: "Bookmark · \(bookmark.folderLine)",
                target: bookmark.url, iconPath: bookmark.appPath, symbol: "bookmark.fill",
                favicon: FaviconStore.host(of: bookmark.url)
            )
        }
    }

    static func historyRows(_ pages: [HistoryPage], colors: String = "#a7aeb8,#5e6670",
                            symbol: String = "clock.arrow.circlepath") -> [SpotlightItem] {
        pages.map { page in
            // The address under the title, like Fluent Search and the browser's own list.
            var address = page.url
            for prefix in ["https://", "http://", "www."] where address.hasPrefix(prefix) {
                address = String(address.dropFirst(prefix.count))
            }
            return SpotlightItem(
                id: "history|" + page.url, name: page.title, kind: .url,
                colors: colors, meta: "\(address)",
                target: page.url, iconPath: page.appPath, symbol: symbol,
                favicon: FaviconStore.host(of: page.url)
            )
        }
    }

    /// Search suggestions. Inside a tag they search that site; untagged, the web (Google).
    static func suggestionRows(_ suggestions: [String], tag: SearchTag?) -> [SpotlightItem] {
        suggestions.map { text in
            if let tag {
                return SpotlightItem(
                    id: "suggest|\(tag.keyword)|\(text)", name: text, kind: .web, colors: tag.colors,
                    meta: "\(tag.name) suggestion", target: tag.url(for: text)?.absoluteString,
                    symbol: "magnifyingglass", favicon: tag.faviconHost
                )
            }
            return SpotlightItem(id: "suggest|\(text)", name: text, kind: .web, colors: "#8fb8ff,#3a6fd8",
                                 meta: "Google suggestion", symbol: "magnifyingglass", favicon: "google.com")
        }
    }

    /// What the second pass of a normal search gathers off the main thread.
    nonisolated struct Extras: Sendable {
        var files: [FileHit] = []
        var bookmarks: [Bookmark] = []
        var history: [HistoryPage] = []
        var blocked = false
    }

    private static func isBrowserRow(_ item: SpotlightItem) -> Bool {
        item.id.hasPrefix("bookmark|") || item.id.hasPrefix("history|") || item.id == "browser|blocked"
    }

    /// Second pass of a normal search. Files stay in charge of the first screen: four local
    /// results, then the two best browser rows (bookmark / history), then more local results,
    /// with the remaining browser rows further down.
    static func addingExtras(_ extras: Extras, term: String, to rows: [SpotlightItem]) -> [SpotlightItem] {
        var out = addingFiles(extras.files, to: rows, term: term)
        let listed = Set(out.compactMap { $0.target?.lowercased() })
        var seenURLs = Set<String>()
        var browserRows = (bookmarkRows(extras.bookmarks) + historyRows(extras.history))
            .filter { !listed.contains(($0.target ?? "").lowercased()) }
            .filter { seenURLs.insert($0.target ?? $0.id).inserted }
        // Blocked by macOS: say so where the browser rows would have been.
        if extras.blocked, browserRows.isEmpty { browserRows = [blockedRow] }
        // One bookmark and one history page up top when both exist.
        if browserRows.count > 2, let firstHistory = browserRows.firstIndex(where: { $0.id.hasPrefix("history|") }),
           firstHistory > 1
        {
            browserRows.insert(browserRows.remove(at: firstHistory), at: 1)
        }
        let leading = out.prefix(8).lastIndex { [.tab, .tagHint, .url].contains($0.kind) }.map { $0 + 1 } ?? 0
        let first = min(max(leading, 4), out.count)
        out.insert(contentsOf: browserRows.prefix(2), at: first)
        let later = min(first + min(browserRows.count, 2) + 6, out.lastIndex { $0.kind == .web && $0.target == nil } ?? out.count)
        out.insert(contentsOf: browserRows.dropFirst(2), at: later)
        return out
    }

    /// Web suggestions arrive last (network): the best one right under the top browser rows so
    /// it is on the first screen, the others a few rows further down.
    static func addingSuggestions(_ suggestions: [String], to rows: [SpotlightItem]) -> [SpotlightItem] {
        let names = Set(rows.filter { $0.kind == .web }.map { $0.name.lowercased() })
        let items = suggestionRows(suggestions.filter { !names.contains($0.lowercased()) }, tag: nil)
        guard !items.isEmpty else { return rows }
        var out = rows
        let webIndex = out.lastIndex { $0.kind == .web && $0.target == nil } ?? out.count
        let afterBrowser = out.prefix(10).lastIndex(where: isBrowserRow).map { $0 + 1 } ?? min(4, out.count)
        let first = min(afterBrowser, webIndex)
        out.insert(items[0], at: first)
        let rest = min(first + 6, out.lastIndex { $0.kind == .web && $0.target == nil } ?? out.count)
        out.insert(contentsOf: items.dropFirst(), at: rest)
        return out
    }

    /// macOS is refusing Lumio access to the browsers' files: say so (⏎ opens the setting)
    /// instead of silently showing no history or bookmarks.
    static var blockedRow: SpotlightItem {
        SpotlightItem(
            id: "browser|blocked", name: "Browser history & bookmarks are blocked by macOS", kind: .setting,
            colors: "#ffb36e,#f06a2e",
            meta: "⏎ open Privacy settings, then turn on Full Disk Access for Lumio",
            target: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            symbol: "lock.fill"
        )
    }

    /// Rows while a web search tag is active: the search itself, the site's open tabs, then
    /// pages of the site you visited recently (newest first).
    static func tagRows(tag: SearchTag, term: String, tabs: [BrowserTab], history: [HistoryPage]) -> [SpotlightItem] {
        let target = tag.url(for: term)?.absoluteString
        let search = SpotlightItem(
            id: "tag|\(tag.keyword)|\(term)",
            name: term.isEmpty ? "Open \(tag.name)" : "Search \(tag.name) for “\(term)”",
            kind: .web, colors: tag.colors,
            meta: term.isEmpty ? (tag.homeURL?.host ?? tag.name) : "\(tag.name) search",
            target: target, symbol: tag.symbol, favicon: tag.faviconHost
        )
        let tabRows = tabs.map(item(from:))
        let openURLs = Set(tabs.map(\.url))
        let historyRows = history.filter { !openURLs.contains($0.url) }.map { page in
            SpotlightItem(
                id: "history|\(page.url)", name: page.title, kind: .url,
                colors: tag.colors, meta: "Visited \(relative(page.lastVisit))",
                target: page.url, iconPath: page.appPath, symbol: tag.symbol,
                favicon: FaviconStore.host(of: page.url)
            )
        }
        return [search] + tabRows + historyRows
    }

    /// Open tabs of a tag's site, narrowed by the typed words.
    nonisolated static func tabs(for tag: SearchTag, matching term: String) -> [BrowserTab] {
        let siteTabs = BrowserTabs.shared.snapshot.filter { tag.matches(url: $0.url) }
        let words = term.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return siteTabs }
        return siteTabs.filter { tab in
            let haystack = (tab.title + " " + tab.url).lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }

    /// File-tag / whole-Mac file hits as rows: when it was last used, and where.
    static func fileRows(_ hits: [FileHit]) -> [SpotlightItem] {
        hits.map { hit in
            let place = PathDisplay.directory(of: hit.path)
            let when = hit.date.map { relative($0) + " · " } ?? ""
            return SpotlightItem(
                id: "file|" + hit.path, name: hit.name, kind: hit.isFolder ? .folder : .doc,
                meta: when + place, target: hit.path, iconPath: hit.path
            )
        }
    }

    /// Merges whole-Mac matches (Spotlight) with Lumio's own file results and orders them the
    /// way Fluent Search does: how well the NAME matches comes first (exact name, then starts
    /// with the text, then a word starts with it, then contains it, then loose fuzzy matches).
    /// Within the same quality: what you picked before, then the MOST RECENT file (so the PSDs
    /// you made this week come before last year's). The top row never moves, so ⏎ stays
    /// predictable, and non-file rows (apps, tabs, links) keep their places.
    static func addingFiles(_ hits: [FileHit], to rows: [SpotlightItem], term: String = "") -> [SpotlightItem] {
        let listed = Set(rows.compactMap { $0.target?.lowercased() })
        let fresh = hits.filter { !listed.contains($0.path.lowercased()) }
        let extra = fileRows(fresh)
        let (words, typedExtensions) = SpotlightFiles.parse(term)
        let needle = words.joined(separator: " ")
        guard !needle.isEmpty else {
            var out = rows
            out.insert(contentsOf: extra, at: out.lastIndex { $0.kind == .web && $0.target == nil } ?? out.count)
            return out
        }

        func isFile(_ item: SpotlightItem) -> Bool {
            (item.kind == .doc || item.kind == .folder) && item.target?.hasPrefix("/") == true
        }
        // When each file was last touched: Spotlight's answer for its hits, the file's own
        // modification date for Lumio's.
        var dates: [String: Date] = [:]
        for hit in hits { dates[hit.path] = hit.date }
        func date(_ item: SpotlightItem) -> Date {
            guard let path = item.target else { return .distantPast }
            if let known = dates[path] { return known }
            let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            dates[path] = stamp ?? .distantPast
            return stamp ?? .distantPast
        }

        let slots = rows.indices.filter { $0 > 0 && isFile(rows[$0]) }
        let pool = slots.map { rows[$0] } + extra
        let ranked = pool.enumerated()
            .map { index, item -> (item: SpotlightItem, tier: Int, weight: Double, date: Date, order: Int) in
                // Code and config files rank after every other file.
                (item, SpotlightFiles.nameScore(item.name.lowercased(), needle: needle, words: words)
                    - (typedExtensions.isEmpty && SpotlightFiles.isLowPriority(item.name) ? 10 : 0),
                 UsageLearning.shared.weight(forTarget: item.target), date(item), index)
            }
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                if lhs.date != rhs.date { return lhs.date > rhs.date }
                return lhs.order < rhs.order
            }
            .map { entry -> SpotlightItem in
                // Lumio's own rows gain the "when" the Spotlight rows already show.
                var item = entry.item
                if item.candidateID != nil, entry.date > .distantPast, let place = item.meta {
                    item.meta = relative(entry.date) + " · " + place
                }
                return item
            }

        var out = rows
        for (slot, item) in zip(slots, ranked) { out[slot] = item }
        let overflow = Array(ranked.dropFirst(slots.count))
        out.insert(contentsOf: overflow, at: out.lastIndex { $0.kind == .web && $0.target == nil } ?? out.count)
        return out
    }

    /// Empty field: recently used apps, then recently opened files.
    static func suggestionRows(apps: [RecentItem], files: [RecentItem]) -> [SpotlightItem] {
        let appRows = apps.map { app in
            SpotlightItem(
                id: "recent|" + app.path, name: app.name, kind: .app,
                target: app.path, iconPath: URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path
            )
        }
        let fileRows = files.map { file in
            SpotlightItem(
                id: "recent|" + file.path, name: file.name, kind: .doc,
                meta: "\(file.isNewDownload ? "Downloaded" : "Opened") \(relative(file.lastUsed)) · \(PathDisplay.directory(of: file.path))",
                target: file.path, iconPath: file.path
            )
        }
        return appRows + fileRows
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - OCR tab

    /// OCR tab: files whose text matches, or one status row (type more / no match / still
    /// indexing / turned off) when there is nothing to list.
    static func contentRows(hits: [ContentHit], term: String, status: ContentIndexStatus) -> [SpotlightItem] {
        let rows = hits.map(item(from:))
        if !rows.isEmpty { return rows }

        let title: String
        if !status.enabled {
            title = "OCR search is turned off"
        } else if term.count < ContentSearchText.minQueryLength {
            title = "Type 3+ characters to search text in images & PDFs"
        } else {
            title = "No text matches “\(term)”"
        }
        return [SpotlightItem(
            id: "content|status", name: title, kind: .content,
            colors: "#a7aeb8,#5e6670", meta: statusLine(status), symbol: "text.viewfinder"
        )]
    }

    private static func statusLine(_ status: ContentIndexStatus) -> String {
        guard status.enabled else { return "Set content_index_enabled=true in ~/.lumio/config" }
        let indexed = "\(status.filesWithText.formatted()) files with text"
        guard status.indexing else { return indexed }
        let remaining = status.pending > 0 ? " — \(status.pending.formatted()) left" : ""
        return indexed + " · reading files\(remaining)…"
    }

    // MARK: - Pinned rows (quick folders, Finder)

    /// Desktop, Documents, …, Applications, Trash and Finder: shown on top when the text
    /// matches their name, since the indexer doesn't cover them (or ranks them low).
    private static func pinned(for request: SpotlightRequest) -> [SpotlightItem] {
        typealias QuickFolder = AppConstants.Launcher.QuickFolder
        typealias Finder = AppConstants.Launcher.Finder
        var scope = LauncherSearchLogic.pinnedLookupScope(for: request.term)
        switch request.browse {
        case nil: break
        case .folder: scope = scope == .unscoped ? .folders : .disabled
        case .app: scope = scope == .unscoped ? .apps : .disabled
        default: scope = .disabled
        }
        guard let needle = LauncherSearchLogic.normalizedPinnedLookupQuery(for: request.term, scope: scope)
        else { return [] }

        var rows: [SpotlightItem] = []
        if scope == .unscoped || scope == .folders {
            for entry in QuickFolder.entries {
                let title = entry.title.lowercased()
                guard title.contains(needle)
                    || (title.hasPrefix(needle) && needle.count >= QuickFolder.minPrefixMatchLength)
                else { continue }
                let path = entry.resolvedPath(homeDirectory: NSHomeDirectory())
                guard FileManager.default.fileExists(atPath: path) else { continue }
                rows.append(SpotlightItem(
                    id: QuickFolder.idPrefix + title, name: entry.title, kind: .folder,
                    meta: entry.subtitle ?? QuickFolder.pinnedSubtitle, target: path, iconPath: path
                ))
            }
        }
        if LauncherSearchLogic.shouldInjectFinder(normalizedQuery: needle, scope: scope) {
            rows.insert(SpotlightItem(
                id: Finder.pinnedResultID, name: "Finder", kind: .app,
                target: Finder.appPath, iconPath: Finder.appPath
            ), at: 0)
        }
        return rows
    }

    /// Prefixes the core understands natively (see core/engine/src/query.rs).
    private static func hasEnginePrefix(_ term: String) -> Bool {
        typealias P = AppConstants.Launcher.QueryPrefix
        let lower = term.lowercased()
        return [P.apps, P.files, P.folders].contains { lower.hasPrefix($0) }
    }

    /// Each item shows only once: apps by name, files/folders by path.
    private static func dedupeKey(_ item: SpotlightItem) -> String {
        switch item.kind {
        case .app: "app:" + item.name.lowercased()
        // Name and content matches of one file collapse into a single row.
        case .doc, .content: "doc:" + (item.target ?? item.id).lowercased()
        case .folder: "folder:" + (item.target ?? item.id).lowercased()
        default: item.id
        }
    }

    /// "Safari.app" → "Safari", like Spotlight.
    private static func displayName(forApp title: String) -> String {
        title.hasSuffix(".app") ? String(title.dropLast(4)) : title
    }

    // MARK: - Actions (⌘K)

    static func actionRows(for item: SpotlightItem, filter: String) -> [SpotlightItem] {
        var actions: [SpotlightAction] = item.kind == .process
            ? [.measureCPU, .killProcess, .copyPID]
            : [.open, .reveal, .copyPath]
        if item.isFileTarget {
            actions += [.openInEditor, .openInTerminal]
            if let trash = trashAction(for: item) { actions.append(trash) }
        }
        if item.kind == .app, let path = item.target {
            if SpotlightOpener.runningApp(at: path) != nil { actions += [.hideApp, .quitApp] }
            actions.append(.excludeApp)
        }
        let needle = fold(filter.trimmingCharacters(in: .whitespacesAndNewlines))
        return actions
            .filter { needle.isEmpty || fold($0.label).contains(needle) }
            .map { action in
                SpotlightItem(
                    id: "action|\(item.id)|\(action.rawValue)", name: action.label, kind: .cmd,
                    colors: "#a7aeb8,#5e6670", meta: item.name,
                    symbol: action.symbol, action: action
                )
            }
    }

    /// ⌘D on a row: Empty Trash on the Trash pin, Move to Trash on any other deletable file/folder,
    /// nil for protected paths (/, home) and the other quick-folder pins.
    static func trashAction(for item: SpotlightItem) -> SpotlightAction? {
        guard item.isFileTarget, let path = item.target else { return nil }
        let home = NSHomeDirectory()
        if DeleteTargetLogic.isTrashPath(path, homeDirectory: home) { return .emptyTrash }
        if DeleteTargetLogic.isQuickFolderPin(item.id) || DeleteTargetLogic.isProtected(path, homeDirectory: home) {
            return nil
        }
        return .moveToTrash
    }

    /// Folds case + diacritics (and đ → d) so "cafe" matches "Café".
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
    }
}
