import Foundation

// Data types for the Spotlight launcher. Real results come from the Rust core via
// SpotlightBackend; SpotlightData is now just sample data for the motion lab.

enum SpotlightKind: String, CaseIterable, Identifiable {
    case app, folder, doc, content, setting, url, web, calc, cmd
    // Modes carried over from the legacy launcher (prefix / command).
    case prefix, command, clip, clipImage, lookup, translation, process, help
    var id: String { rawValue }

    var label: String {
        switch self {
        case .app: "Applications"
        case .folder: "Folders"
        case .doc: "Documents"
        case .content: "OCR"
        case .setting: "Settings"
        case .url: "Links"
        case .web: "Web"
        case .calc: "Calculator"
        case .cmd: "Actions"
        case .prefix: "Prefixes"
        case .command: "Commands"
        case .clip: "Clipboard"
        case .clipImage: "Copied Images"
        case .lookup: "Lookup"
        case .translation: "Translations"
        case .process: "Processes"
        case .help: "Help"
        }
    }

    /// Filter pill a row belongs to. System Settings rows have no pill of their own:
    /// they sit under Applications.
    var pillGroup: SpotlightKind {
        self == .setting ? .app : self
    }

    /// A file on disk matched by name (.doc) or by its text (.content).
    var isDocument: Bool { self == .doc || self == .content }
}

/// What can be done with an item when you open its actions (⌘K).
enum SpotlightAction: String {
    case open, reveal, copyPath, openInEditor, openInTerminal, moveToTrash, emptyTrash
    case hideApp, quitApp, excludeApp
    // Process rows (ps").
    case measureCPU, killProcess, copyPID

    var label: String {
        switch self {
        case .open: "Open"
        case .reveal: "Show in Finder"
        case .copyPath: "Copy Path"
        case .openInEditor: "Open in Editor  ⌘E"
        case .openInTerminal: "Open in Terminal  ⌘T"
        case .moveToTrash: "Move to Trash  ⌘D"
        case .emptyTrash: "Empty Trash  ⌘D"
        case .hideApp: "Hide App"
        case .quitApp: "Quit App"
        case .excludeApp: "Hide from Results  ⌘⇧H"
        case .measureCPU: "Measure CPU"
        case .killProcess: "Force Quit"
        case .copyPID: "Copy PID"
        }
    }

    var symbol: String {
        switch self {
        case .open: "arrow.up.forward.app"
        case .reveal: "folder"
        case .copyPath: "doc.on.doc"
        case .openInEditor: "pencil"
        case .openInTerminal: "terminal"
        case .moveToTrash: "trash"
        case .emptyTrash: "trash.slash"
        case .hideApp: "eye.slash"
        case .quitApp: "xmark.circle"
        case .excludeApp: "nosign"
        case .measureCPU: "gauge.with.dots.needle.50percent"
        case .killProcess: "xmark.octagon"
        case .copyPID: "number"
        }
    }
}

struct SpotlightItem: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: SpotlightKind
    /// "c1,c2" — gradient background of the icon tile when there is no real icon.
    var colors: String = "#9aa2ad,#5c636e"
    var glyph: String? = nil
    var meta: String? = nil
    var rank: Int = 0
    /// Calculation result (only kind == .calc)
    var calcResult: Double? = nil
    var score: Double = 0
    /// Target to open: an app/file/folder path, or a URL
    /// (`x-apple.systempreferences:…`, `https:…`).
    var target: String? = nil
    /// Load the real icon from this path (NSWorkspace). nil = draw a colored tile.
    var iconPath: String? = nil
    /// SF Symbol drawn on the colored tile when there is no real icon.
    var symbol: String? = nil
    /// Candidate id in the core, used to record usage. nil for synthesized rows.
    var candidateID: String? = nil
    /// Action row (⌘K actions mode).
    var action: SpotlightAction? = nil
    /// Process (ps" / :kill).
    var pid: Int32? = nil
    /// Per-mode value: prefix to fill in, command id, copied text,
    /// copied image hash, word to look up.
    var payload: String? = nil
    /// Text clipboard row: id in ClipboardHistoryStore.
    var clipID: UUID? = nil

    /// A real file or folder on disk (not a URL scheme), the target of editor/terminal/trash.
    var isFileTarget: Bool {
        (kind.isDocument || kind == .folder) && target?.hasPrefix("/") == true
    }

    /// Has an actions view (⌘K).
    var supportsActions: Bool {
        if kind == .process { return pid != nil }
        return (kind == .app || kind.isDocument || kind == .folder) && target != nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - Sample data (motion lab / Preview only)

enum SpotlightData {
    static let items: [SpotlightItem] = [
        .app("Flux.app", "#ffd166,#f0733d", "☀", 9),
        .app("Finder.app", "#7ac6ff,#2b7ae0", "☺", 8),
        .app("Figma.app", "#f06a6a,#7a5af5", nil, 6),
        .app("Find My.app", "#5fd97a,#1f9d4d", "◎", 4),
        .app("FaceTime.app", "#6ee07a,#1fa34a", "▣", 4),
        .app("Freeform.app", "#5fe3e8,#1a7f9c", "〜", 3),
        .app("File Manager.app", "#8fa4bd,#5b6c82", nil, 2),
        .app("Safari.app", "#79d0ff,#1f6fd0", "◍", 7),
        .folder("Documents", "Users ▸ Documents", 5),
        .folder("Downloads", "Users ▸ Downloads", 6),
        .doc("Q3 Report.pdf", "Documents ▸ Reports", "📕", 4),
        .setting("Wi‑Fi", "System Settings"),
    ]
}

private extension SpotlightItem {
    static func app(_ name: String, _ c: String, _ glyph: String?, _ rank: Int) -> Self {
        SpotlightItem(id: "app|\(name)", name: name, kind: .app, colors: c, glyph: glyph, rank: rank)
    }
    static func folder(_ name: String, _ path: String, _ rank: Int) -> Self {
        SpotlightItem(id: "folder|\(name)", name: name, kind: .folder, colors: "#6cb8f5,#2f7fe0", glyph: "📁", meta: path, rank: rank)
    }
    static func doc(_ name: String, _ path: String, _ glyph: String, _ rank: Int) -> Self {
        SpotlightItem(id: "doc|\(name)", name: name, kind: .doc, colors: "#dfe3ea,#b6bdc9", glyph: glyph, meta: path, rank: rank)
    }
    static func setting(_ name: String, _ meta: String) -> Self {
        SpotlightItem(id: "setting|\(name)", name: name, kind: .setting, colors: "#9aa2ad,#5c636e", glyph: "⚙️", meta: meta)
    }
}

// MARK: - Calculator (+ - * / % ^ ())

nonisolated enum SpotlightCalc {
    static func evaluate(_ src: String) -> Double? {
        guard src.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        guard src.contains(where: { "+-*/^%".contains($0) }) else { return nil }
        guard src.range(of: "^[0-9\\s.,()+\\-*/^%]+$", options: .regularExpression) != nil else { return nil }
        var tokens: [String] = []
        var buf = ""
        func flush() { if !buf.isEmpty { tokens.append(buf); buf = "" } }
        for ch in src.replacingOccurrences(of: ",", with: "") {
            if ch.isNumber || ch == "." { buf.append(ch) }
            else if "+-*/^%()".contains(ch) { flush(); tokens.append(String(ch)) }
            else if ch.isWhitespace { flush() }
            else { return nil }
        }
        flush()
        guard !tokens.isEmpty else { return nil }
        var p = 0
        func peek() -> String? { p < tokens.count ? tokens[p] : nil }
        func eat(_ x: String) -> Bool { if peek() == x { p += 1; return true }; return false }
        func expr() -> Double? {
            guard var v = term() else { return nil }
            while peek() == "+" || peek() == "-" {
                let op = tokens[p]; p += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }
        func term() -> Double? {
            guard var v = unary() else { return nil }
            while peek() == "*" || peek() == "/" || peek() == "%" {
                let op = tokens[p]; p += 1
                guard let r = unary() else { return nil }
                if op == "*" { v *= r } else if op == "/" { v /= r } else { v = v.truncatingRemainder(dividingBy: r) }
            }
            return v
        }
        func unary() -> Double? {
            if eat("-") { guard let v = unary() else { return nil }; return -v }
            if eat("+") { return unary() }
            return power()
        }
        func power() -> Double? {
            guard let base = primary() else { return nil }
            if eat("^") { guard let e = unary() else { return nil }; return pow(base, e) }
            return base
        }
        func primary() -> Double? {
            if eat("(") { guard let v = expr(), eat(")") else { return nil }; return v }
            guard let t = peek(), Double(t) != nil else { return nil }
            p += 1
            return Double(t)
        }
        guard let val = expr(), p == tokens.count, val.isFinite else { return nil }
        return (val * 1e10).rounded() / 1e10
    }

    static func format(_ n: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.maximumFractionDigits = 10
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
