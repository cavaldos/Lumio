//
//  SpotlightModes.swift
//  lumio-app
//
//  The legacy launcher's prefixes and commands, running inside the Spotlight launcher:
//
//    a" f" d" r" rc"   — core filters (go straight to EngineBridge, see SpotlightBackend)
//    "                 — menu listing every prefix (PrefixSuggestion)
//    c"  ci"           — text / image clipboard history (ClipboardHistoryStore)
//    tw"               — word lookup: EN/VI/JA translation + system dictionary
//    ps"               — find / measure CPU / force quit processes (ProcessFinderModel)
//    :                 — command menu; :kill  :speed  (or ⌘/ opens the most recent command)
//
//  Reuses the legacy launcher's modules as-is; only the rows are built Spotlight-style.
//

import AppKit
import CoreServices

enum SpotlightMode: Equatable {
    case search
    case prefixMenu(filter: String)
    case commandMenu(filter: String)
    case clipboard(term: String)
    case clipboardImage(term: String)
    case lookup(word: String)
    case process(term: String)

    private typealias Prefix = AppConstants.Launcher.QueryPrefix

    /// Same rules as the legacy launcher.
    static func parse(_ query: String) -> SpotlightMode {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if let term = ClipboardQueryPrefix.image.searchTerm(in: trimmed) { return .clipboardImage(term: term) }
        if let term = ClipboardQueryPrefix.text.searchTerm(in: trimmed) { return .clipboard(term: term) }
        if let term = LauncherProcessFeature.searchTerm(from: trimmed) { return .process(term: term) }
        if lower.hasPrefix(Prefix.translateWord) {
            let word = String(trimmed.dropFirst(Prefix.translateWord.count))
            return .lookup(word: word.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if trimmed.hasPrefix(Prefix.discovery) {
            return .prefixMenu(filter: String(trimmed.dropFirst(Prefix.discovery.count)))
        }
        if trimmed.hasPrefix(":") { return .commandMenu(filter: String(trimmed.dropFirst())) }
        return .search
    }

    /// Key hint in the panel footer for this mode.
    var footerHint: String {
        switch self {
        case .search: "⏎ open   ⇥ actions"
        case .prefixMenu: "⏎ use prefix"
        case .commandMenu: "⏎ enter command"
        case .clipboard, .clipboardImage: "⏎ copy"
        case .lookup: "definitions on the right"
        case .process: "⏎ measure CPU   ⇥ actions"
        }
    }
}

/// Commands (`:kill`, `:speed`) — the catalog belongs to the legacy launcher.
enum SpotlightCommands {
    static let kill = AppConstants.Launcher.Command.kill
    static let speed = AppConstants.Launcher.Command.speed

    static var catalog: [AppCommand] { AppConstants.Launcher.commandCatalog }

    static func placeholder(for id: String) -> String {
        switch id {
        case kill: "Name, PID or port"
        case speed: "⏎ re-run network speed test"
        default: id
        }
    }

    static func detail(for command: AppCommand) -> String {
        switch command.id {
        case kill: "Force quit an app / process by name, PID or port"
        case speed: "Measure download, upload speed and latency"
        default: command.detail
        }
    }

    /// `:kill chrome` (with a space) goes straight into the command with the rest as its argument.
    static func inlineTrigger(_ filter: String) -> (id: String, args: String)? {
        guard let space = filter.firstIndex(where: \.isWhitespace) else { return nil }
        let id = filter[..<space].lowercased()
        guard catalog.contains(where: { $0.id == id }) else { return nil }
        return (id, String(filter[filter.index(after: space)...]))
    }
}

/// Builds the rows for each mode.
enum SpotlightModeRows {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static func prefixMenu(_ filter: String) -> [SpotlightItem] {
        AppConstants.Launcher.PrefixSuggestion.menuEntries(matching: filter).map { entry in
            SpotlightItem(
                id: "prefix|\(entry.prefix)", name: entry.displayWithArg, kind: .prefix,
                colors: "#a7aeb8,#5e6670", meta: entry.description,
                symbol: "text.cursor", payload: entry.prefix
            )
        }
    }

    static func commandMenu(_ filter: String) -> [SpotlightItem] {
        AppConstants.Launcher.commandCatalog(matching: filter).enumerated().map { index, command in
            SpotlightItem(
                id: "command|\(command.id)", name: ":\(command.id)", kind: .command,
                colors: "#8fb8ff,#3a6fd8", meta: "\(SpotlightCommands.detail(for: command))  ⌘\(index + 1)",
                symbol: command.symbolName, payload: command.id
            )
        }
    }

    static func clipboard(_ store: ClipboardHistoryStore, term: String) -> [SpotlightItem] {
        store.search(term).map { entry in
            SpotlightItem(
                id: "clip|\(entry.id.uuidString)", name: entry.title, kind: .clip,
                colors: "#c3a6ff,#7a52d6",
                meta: "\(entry.characterCount) characters · \(timeFormatter.string(from: entry.capturedAt))",
                symbol: "doc.on.clipboard", payload: entry.payload ?? entry.content, clipID: entry.id
            )
        }
    }

    static func clipboardImages(_ store: ClipboardHistoryStore, term: String) -> [SpotlightItem] {
        store.searchImages(term).map { entry in
            let size = ByteCountFormatter.string(fromByteCount: Int64(entry.byteSize), countStyle: .file)
            return SpotlightItem(
                id: "clipimage|\(entry.id)", name: entry.label, kind: .clipImage,
                colors: "#c3a6ff,#7a52d6",
                meta: "\(Int(entry.pixelSize.width))×\(Int(entry.pixelSize.height)) · \(size)",
                target: entry.fileURL?.path, iconPath: entry.thumbnailURL?.path ?? entry.fileURL?.path,
                symbol: "photo", payload: entry.id
            )
        }
    }

    static func lookup(_ word: String) -> [SpotlightItem] {
        guard !word.isEmpty else { return [] }
        return [SpotlightItem(
            id: "lookup|\(word)", name: word, kind: .lookup,
            colors: "#ffb36e,#f06a2e", meta: "Translate + dictionary",
            symbol: "character.book.closed", payload: word
        )]
    }

    static func processes(_ model: ProcessFinderModel, term: String) -> [SpotlightItem] {
        let lowered = term.lowercased()
        let ranked = model.ranked(term: term) { title in
            EngineBridge.shared.fuzzyScore(query: lowered, title: title)
        }
        return ranked.prefix(AppConstants.Launcher.Process.resultLimit).map { candidate in
            var meta = "PID \(candidate.pid)"
            if !candidate.ports.isEmpty {
                meta += " · " + candidate.ports.map { ":\($0)" }.joined(separator: " ")
            }
            return SpotlightItem(
                id: "process|\(candidate.pid)",
                name: candidate.name.isEmpty ? "Process \(candidate.pid)" : candidate.name,
                kind: .process, meta: meta, pid: candidate.pid
            )
        }
    }

    /// `:kill` — running apps first, then processes; same ranking as the legacy launcher.
    static func killTargets(_ model: ProcessFinderModel, term: String) -> [SpotlightItem] {
        KillCommand.suggestions(searchTerm: term, processes: model.candidates).map { candidate in
            SpotlightItem(
                id: "kill|\(candidate.pid)", name: candidate.displayName, kind: .process,
                meta: "PID \(candidate.pid)", pid: candidate.pid
            )
        }
    }

    // MARK: - Word lookup (tw")

    /// Like the legacy launcher's `fetchAllTranslations`: translate (network call) on a
    /// background thread, look up the system dictionary for the translations on main.
    static func fetchLookup(_ word: String) async -> LookupDefinition {
        async let en = translate(word, to: "en")
        async let vi = translate(word, to: "vi")
        async let ja = translate(word, to: "ja")
        let results = await [("English", en), ("Vietnamese", vi), ("Japanese", ja)]
        return LookupDefinition(
            query: word,
            sourceLabel: "Input",
            sections: results.map { label, translated in
                LookupTranslationSection(
                    label: label,
                    translated: translated,
                    dictionaryDefinition: translated.flatMap { DictionaryParser.parse(rawDefinition(for: $0) ?? "") },
                    failed: translated == nil
                )
            }
        )
    }

    private static func translate(_ text: String, to lang: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            EngineBridge.shared.translate(text: text, targetLang: lang)?.translated
        }.value
    }

    private static func rawDefinition(for text: String) -> String? {
        let range = CFRange(location: 0, length: (text as NSString).length)
        guard let unmanaged = DCSCopyTextDefinition(nil, text as CFString, range) else { return nil }
        let raw = (unmanaged.takeRetainedValue() as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}
