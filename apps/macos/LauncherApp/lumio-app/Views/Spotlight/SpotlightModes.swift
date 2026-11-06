//
//  SpotlightModes.swift
//  lumio-app
//
//  The legacy launcher's prefixes and commands, running inside the Spotlight launcher:
//
//    a" f" d" r" rc"   — core filters (go straight to EngineBridge, see SpotlightBackend)
//    "                 — menu listing every prefix (PrefixSuggestion)
//    c"  ci"           — text / image clipboard history (ClipboardHistoryStore)
//    tw"               — word lookup: system dictionary (Dictionary.app style) + EN/VI/JA translation
//    tr"               — translate text into EN / VI / JA (Apple Translation, see TextTranslator)
//    ps"               — find / measure CPU / force quit processes (ProcessFinderModel)
//    :                 — command menu; :kill  :emptytrash  :help  (or ⌘/ opens the most recent command)
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
    case translate(text: String)
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
        if lower.hasPrefix(Prefix.translate) {
            let text = String(trimmed.dropFirst(Prefix.translate.count))
            return .translate(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
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
        case .search: "⏎ open   ⇥ filter   ⌘K actions"
        case .prefixMenu: "⏎ use prefix"
        case .commandMenu: "⏎ enter command"
        case .clipboard, .clipboardImage: "⏎ copy"
        case .lookup: "click a linked word to look it up"
        case .translate: "⏎ copy translation"
        case .process: "⏎ measure CPU   ⌘K actions"
        }
    }
}

/// Commands (`:kill`, `:emptytrash`, `:help`).
enum SpotlightCommands {
    static let kill = AppConstants.Launcher.Command.kill
    static let emptyTrash = AppConstants.Launcher.Command.emptyTrash
    static let help = AppConstants.Launcher.Command.help

    static var catalog: [AppCommand] { AppConstants.Launcher.commandCatalog }

    static func placeholder(for id: String) -> String {
        switch id {
        case kill: "Name, PID or port"
        case emptyTrash: "⏎ empty the Trash"
        case help: "Filter help"
        default: id
        }
    }

    static func detail(for command: AppCommand) -> String {
        switch command.id {
        case kill: "Force quit an app / process by name, PID or port"
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

    /// tw": the words starting with the typed text in the enabled dictionaries, like the
    /// Dictionary.app sidebar. The typed text always comes first, even when no dictionary
    /// has it (a phrase to translate).
    static func lookup(_ word: String) -> [SpotlightItem] {
        guard !word.isEmpty else { return [] }
        var words = DictionaryLookupService.suggestions(for: word)
        if let index = words.firstIndex(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            words.insert(words.remove(at: index), at: 0)
        } else {
            words.insert(word, at: 0)
        }
        return words.map { headword in
            SpotlightItem(
                id: "lookup|\(headword)", name: headword, kind: .lookup,
                colors: "#ffb36e,#f06a2e", meta: nil,
                symbol: "character.book.closed", payload: headword
            )
        }
    }

    /// tr": one row per target language. The translations live in the view's state
    /// (SpotlightTranslationBatch), so the rows stay put while they fill in.
    static func translation(_ text: String, source: Locale.Language?) -> [SpotlightItem] {
        guard !text.isEmpty else { return [] }
        return TranslationLanguage.targets(from: source).map { language in
            SpotlightItem(
                id: "translate|\(language.code)", name: language.name, kind: .translation,
                colors: "#7fb2ff,#3d63e0", meta: language.name,
                symbol: "translate", payload: language.code
            )
        }
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

    /// `:emptytrash` — one row; the first Enter asks, the second empties.
    static func emptyTrash(itemCount: Int?) -> [SpotlightItem] {
        let detail = itemCount.map(DeleteTargetLogic.emptyTrashDetail(itemCount:)) ?? "Deleted permanently"
        return [SpotlightItem(
            id: "command|emptytrash", name: "Empty Trash", kind: .command,
            colors: "#ff8a80,#d6453a", meta: detail, symbol: "trash.slash",
            payload: SpotlightCommands.emptyTrash
        )]
    }

    /// `:help` — prefixes, commands and keyboard shortcuts of this launcher.
    static func help(_ filter: String) -> [SpotlightItem] {
        let prefixes = AppConstants.Launcher.PrefixSuggestion.menuEntries(matching: "").map {
            ($0.displayWithArg, $0.description)
        }
        let commands = AppConstants.Launcher.commandCatalog.map { (":" + $0.id, SpotlightCommands.detail(for: $0)) }
        let entries = prefixes + commands + helpShortcuts
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries
            .filter { needle.isEmpty || $0.0.lowercased().contains(needle) || $0.1.lowercased().contains(needle) }
            .map { key, detail in
                SpotlightItem(
                    id: "help|\(key)", name: key, kind: .help,
                    colors: "#a7aeb8,#5e6670", meta: detail, symbol: "keyboard"
                )
            }
    }

    private static let helpShortcuts: [(String, String)] = [
        ("⌘K", "Actions for the selected row"),
        ("⇥ / ⇧⇥", "Next / previous filter"),
        ("⌘1 … ⌘4", "Browse Applications, Folders, Documents, OCR (text in images & PDFs)"),
        ("⌘↩", "Search the web"),
        ("⌘F", "Show in Finder"),
        ("⌘E", "Open in editor"),
        ("⌘T", "Open in terminal"),
        ("⌘D", "Move to Trash · Empty Trash on the Trash pin · delete a clip"),
        ("⌘H", "This help"),
        ("⌘⇧H", "Hide the selected app from results"),
        ("⌘/", "Open the last command"),
        ("⌘⇧,", "Settings"),
        ("Esc", "Leave the current mode, or close"),
    ]

    // MARK: - Translation (tw" bar, tr")

    /// EN / VI / JA translations of a word, for the tw" bar.
    static func fetchTranslations(_ word: String) async -> [SpotlightTranslation] {
        let source = TextTranslator.detectLanguage(of: word)
        let results = await translate(word, from: source, to: TranslationLanguage.all)
        return TranslationLanguage.all.map { language in
            SpotlightTranslation(label: language.name, code: language.shortCode, text: results[language.code]?.text)
        }
    }

    /// Translates `text` into every target at once. Keyed by language code; a missing code failed.
    static func translate(
        _ text: String,
        from source: Locale.Language?,
        to targets: [TranslationLanguage]
    ) async -> [String: TextTranslation] {
        await withTaskGroup(of: (String, TextTranslation?).self) { group in
            for target in targets {
                group.addTask { (target.code, await TextTranslator.translate(text, from: source, to: target)) }
            }
            var results: [String: TextTranslation] = [:]
            for await (code, translation) in group {
                results[code] = translation
            }
            return results
        }
    }
}
