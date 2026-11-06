//
//  SpotlightBackend.swift
//  lumio-app
//
//  Connects the Spotlight launcher to the Rust core (EngineBridge → bridge/ffi → QueryEngine).
//
//  Flow of a single search:
//  1. `engineQuery(for:)` builds the query string for the core. The 4 round buttons use the core's
//     own filter prefixes: a" (app), d" (folder), f" (file). System settings
//     are apps with a `setting:` id, so they go through a" and are filtered again.
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
    static let resultLimit = 40
    /// The core returns at most 100 rows per call (MAX_SEARCH_LIMIT in bridge/ffi).
    private static let engineMaxLimit = 100
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
        case .setting:
            // Empty field: "settings" is a settings-style query; the core puts every settings
            // item on top instead of mixing them with apps as when browsing plain a".
            let text = term.isEmpty ? "settings" : term
            return SpotlightEngineQuery(text: "a\"" + text, limit: engineMaxLimit)
        default:
            return SpotlightEngineQuery(text: term, limit: resultLimit)
        }
    }

    // MARK: - Core results → display rows

    static func rows(
        from results: [LauncherResult],
        for request: SpotlightRequest,
        recentURLs: [URLHistoryEntry] = []
    ) -> [SpotlightItem] {
        // Pinned rows go on top, except below a same-named app (Music.app stays ahead of ~/Music).
        var candidates = results.compactMap(item(from:))
        for pin in pinned(for: request).reversed() {
            let rival = candidates.firstIndex { $0.kind == .app && $0.name.lowercased() == pin.name.lowercased() }
            candidates.insert(pin, at: rival.map { $0 + 1 } ?? 0)
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
        // or once a core filter prefix has been typed (a" f" d" r" rc").
        let term = request.term
        guard request.browse == nil, !term.isEmpty, !hasEnginePrefix(term) else { return rows }

        var leading: [SpotlightItem] = []
        if let value = SpotlightCalc.evaluate(term) {
            leading.append(SpotlightItem(
                id: "calc|\(term)", name: term, kind: .calc,
                colors: "#9aa2ad,#4d545d", calcResult: value, symbol: "equal"
            ))
        }
        if let match = EngineBridge.shared.classifyURL(query: term) {
            let row = SpotlightItem(
                id: "url|\(match.url)", name: match.url, kind: .url,
                colors: "#8fb8ff,#3a6fd8", meta: "Open link",
                target: match.url, symbol: "link"
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
                target: entry.url, symbol: "clock.arrow.circlepath"
            )
        }
        rows.insert(contentsOf: recents, at: min(1, rows.count))
        let web = SpotlightItem(
            id: "web|\(term)", name: term, kind: .web,
            colors: "#8fb8ff,#3a6fd8", meta: "Search the web", symbol: "globe"
        )
        return leading + rows + [web]
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
        return [P.apps, P.files, P.folders, P.regex, P.recent].contains { lower.hasPrefix($0) }
    }

    /// Each item shows only once: apps by name, files/folders by path.
    private static func dedupeKey(_ item: SpotlightItem) -> String {
        switch item.kind {
        case .app: "app:" + item.name.lowercased()
        case .doc, .folder: item.kind.rawValue + ":" + (item.target ?? item.id).lowercased()
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
