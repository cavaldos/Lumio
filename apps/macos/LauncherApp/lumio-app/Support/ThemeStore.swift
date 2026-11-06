import AppKit
import Combine
import Foundation
import ServiceManagement

/// App settings kept in the config file (`~/.lumio/config`) and edited in Settings:
/// file indexing, log level, launch at login, translation languages.
final class ThemeStore: ObservableObject {
    // Shared so AppDelegate (which hosts ContentView in an AppKit window), the
    // Settings window and the launcher use the same store.
    static let shared = ThemeStore()

    @Published var settings: ThemeSettings {
        didSet { save() }
    }

    @Published private(set) var excludedFolderPaths: [String] = []
    @Published private(set) var fileScanRoots: [String] = []
    @Published private(set) var extraFileScanRoots: [String] = []

    enum AddExtraScanRootError: Error {
        case notDirectory
        case alreadyIncluded
        case overlapsExistingRoot(String)
        case riskySystemRoot

        var message: String {
            switch self {
            case .notDirectory:
                return "Please select a directory"
            case .alreadyIncluded:
                return "Directory is already covered by scan roots"
            case let .overlapsExistingRoot(path):
                return "Overlaps with existing root: \(path)"
            case .riskySystemRoot:
                return "Refusing risky system root (/, /System, /Library, /private)"
            }
        }
    }

    private let defaultsKey = "lumio.theme.settings"

    init() {
        Self.ensureDefaultConfigFileExists(at: Self.configPath())
        Self.migrateLegacyDefaults(key: defaultsKey)
        settings = Self.loadThemeSettings(from: UserDefaults.standard.data(forKey: defaultsKey))
        applyOverridesFromConfigFile()
        _ = applyLaunchAtLoginSetting()
    }

    /// The bundle id used to be `noah-code.Lumio`, so theme settings saved before
    /// the rename live in that domain. Copy them over once so they survive.
    private static func migrateLegacyDefaults(key: String) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) == nil,
            let bundleID = Bundle.main.bundleIdentifier,
            bundleID.hasPrefix("com.cavaldos.Lumio"),
            let legacy = UserDefaults(
                suiteName: bundleID.replacingOccurrences(of: "com.cavaldos.Lumio", with: "noah-code.Lumio")),
            let data = legacy.data(forKey: key)
        else { return }
        defaults.set(data, forKey: key)
    }

    struct ConfigReloadResult {
        let warnings: [String]
    }

    func reloadFromConfig() -> ConfigReloadResult {
        let configPath = Self.configPath()
        Self.ensureDefaultConfigFileExists(at: configPath)

        var warnings: [String] = []
        if let raw = try? String(contentsOf: configPath, encoding: .utf8) {
            let values = ConfigFileLines.keyValues(raw)
            if let value = values["file_scan_depth"], let parsed = Int(value),
               !(AppConstants.FileScan.minDepth...AppConstants.FileScan.maxDepth).contains(parsed)
            {
                warnings.append("file_scan_depth=\(value) invalid (must be \(AppConstants.FileScan.minDepth)-\(AppConstants.FileScan.maxDepth))")
            }
            if let value = values["file_scan_limit"], let parsed = Int(value),
               !(AppConstants.FileScan.minLimit...AppConstants.FileScan.maxLimit).contains(parsed)
            {
                warnings.append("file_scan_limit=\(value) invalid (must be \(AppConstants.FileScan.minLimit)-\(AppConstants.FileScan.maxLimit))")
            }
        }

        applyOverridesFromConfigFile()
        _ = applyLaunchAtLoginSetting()
        return ConfigReloadResult(warnings: warnings)
    }

    func saveCurrentConfigToFile() -> Bool {
        let path = Self.configPath()
        Self.ensureDefaultConfigFileExists(at: path)

        // A failed read must not fall through to an empty parse: saving on top of
        // nothing would drop every other setting, comment and blank line in the file.
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else {
            return false
        }
        var lines = ConfigFileLines.parse(raw)
        ConfigFileLines.upsert(&lines, key: "file_scan_depth", value: String(settings.fileScanDepth))
        ConfigFileLines.upsert(&lines, key: "file_scan_limit", value: String(settings.fileScanLimit))
        ConfigFileLines.upsert(&lines, key: "lazy_indexing_enabled", value: settings.lazyIndexingEnabled ? "true" : "false")
        ConfigFileLines.upsert(&lines, key: "file_exclude_paths", value: ConfigFileLines.renderList(excludedFolderPaths))
        ConfigFileLines.upsert(&lines, key: "file_scan_extra_roots", value: ConfigFileLines.renderList(extraFileScanRoots))
        ConfigFileLines.upsert(&lines, key: "backend_log_level", value: settings.backendLogLevel.rawValue)
        ConfigFileLines.upsert(&lines, key: "launch_at_login", value: settings.launchAtLogin ? "true" : "false")
        ConfigFileLines.upsert(&lines, key: "translation_languages", value: settings.translationLanguages.joined(separator: ","))

        do {
            try ConfigFileLines.render(lines).write(to: path, atomically: true, encoding: .utf8)
            _ = applyLaunchAtLoginSetting()
            return true
        } catch {
            return false
        }
    }

    func regenerateFreshConfigFile() -> Bool {
        let path = Self.configPath()
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                try FileManager.default.removeItem(at: path)
            } catch {
                return false
            }
        }

        Self.ensureDefaultConfigFileExists(at: path)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return false
        }

        settings = .default
        applyOverridesFromConfigFile()
        _ = applyLaunchAtLoginSetting()
        return true
    }

    func addExcludedFolderPath(url: URL) {
        let normalizedPath = normalizeExcludedFolderPath(url.path)
        guard !normalizedPath.isEmpty else {
            return
        }
        if excludedFolderPaths.contains(normalizedPath) {
            return
        }
        excludedFolderPaths.append(normalizedPath)
        excludedFolderPaths.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func removeExcludedFolderPath(_ path: String) {
        let normalizedPath = normalizeExcludedFolderPath(path)
        excludedFolderPaths.removeAll { $0 == normalizedPath }
    }

    @discardableResult
    func addExtraFileScanRoot(url: URL) -> AddExtraScanRootError? {
        let normalizedPath = normalizeFileScanRootPath(url.path)
        guard !normalizedPath.isEmpty else {
            return .notDirectory
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .notDirectory
        }

        if isRiskyRoot(normalizedPath) {
            return .riskySystemRoot
        }

        if fileScanRoots.contains(where: { pathContains($0, normalizedPath) || pathContains(normalizedPath, $0) }) {
            return .alreadyIncluded
        }

        if let overlap = extraFileScanRoots.first(where: { pathContains($0, normalizedPath) || pathContains(normalizedPath, $0) }) {
            return .overlapsExistingRoot(overlap)
        }

        extraFileScanRoots.append(normalizedPath)
        extraFileScanRoots.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return nil
    }

    func removeExtraFileScanRoot(_ path: String) {
        let normalizedPath = normalizeFileScanRootPath(path)
        extraFileScanRoots.removeAll { $0 == normalizedPath }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Invalid values are ignored and the current ones kept, so a broken line never
    /// stops the app. Old `ui_*` theme keys are left in the file and ignored.
    private func applyOverridesFromConfigFile() {
        guard let raw = try? String(contentsOf: Self.configPath(), encoding: .utf8) else {
            return
        }

        excludedFolderPaths = []
        fileScanRoots = defaultFileScanRoots()
        extraFileScanRoots = []

        for (key, value) in ConfigFileLines.keyValues(raw) {
            switch key {
            case "file_scan_depth":
                if let parsed = parsePositiveInt(value) { settings.fileScanDepth = parsed }
            case "file_scan_limit":
                if let parsed = parsePositiveInt(value) { settings.fileScanLimit = parsed }
            case "lazy_indexing_enabled":
                if let parsed = parseBool(value) { settings.lazyIndexingEnabled = parsed }
            case "file_exclude_paths":
                excludedFolderPaths = parseExcludedFolderPaths(value)
            case "file_scan_roots":
                let parsed = parseFileScanRootPaths(value)
                if !parsed.isEmpty { fileScanRoots = parsed }
            case "file_scan_extra_roots":
                extraFileScanRoots = parseFileScanRootPaths(value)
            case "backend_log_level":
                if let parsed = parseBackendLogLevel(value) { settings.backendLogLevel = parsed }
            case "launch_at_login":
                if let parsed = parseBool(value) { settings.launchAtLogin = parsed }
            case "translation_languages":
                let codes = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let known = codes.filter { TranslationLanguage.named($0) != nil }
                if !known.isEmpty { settings.translationLanguages = Array(known.prefix(TranslationLanguage.maxSelected)) }
            default:
                continue
            }
        }
    }

    private static func configPath() -> URL {
        URL(fileURLWithPath: ConfigPathResolver.resolvedPath())
    }

    /// Writes the default config when there is none, and otherwise undoes the damage
    /// left by builds that duplicated their own section header on every save. Runs at
    /// launch and on reload, so an affected config heals without the user having to go
    /// and save something.
    ///
    /// A config that does not carry the damage is left byte-identical, not merely
    /// equivalent: rewriting it would reformat a layout the user chose, and would bump
    /// the mtime and wake the config watcher on every launch.
    private static func ensureDefaultConfigFileExists(at path: URL) {
        guard FileManager.default.fileExists(atPath: path.path) else {
            try? defaultConfigContents.write(to: path, atomically: true, encoding: .utf8)
            return
        }

        guard let raw = try? String(contentsOf: path, encoding: .utf8),
              let repaired = ConfigFileLines.repairingLegacyDamage(raw)
        else {
            return
        }

        try? repaired.write(to: path, atomically: true, encoding: .utf8)
    }

    private func parsePositiveInt(_ value: String) -> Int? {
        guard let parsed = Int(value), parsed > 0 else {
            return nil
        }
        return parsed
    }

    private func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func parseBackendLogLevel(_ value: String) -> BackendLogLevel? {
        BackendLogLevel(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func parseExcludedFolderPaths(_ value: String) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for token in ConfigFileLines.parseList(value) {
            let normalized = normalizeExcludedFolderPath(token)
            if normalized.isEmpty || seen.contains(normalized) {
                continue
            }
            seen.insert(normalized)
            paths.append(normalized)
        }
        return paths.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func normalizeExcludedFolderPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        let expanded = expandConfigLikePath(trimmed)
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func parseFileScanRootPaths(_ value: String) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for token in ConfigFileLines.parseList(value) {
            let normalized = normalizeFileScanRootPath(token)
            if normalized.isEmpty || seen.contains(normalized) {
                continue
            }
            seen.insert(normalized)
            paths.append(normalized)
        }
        return paths.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func normalizeFileScanRootPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        let expanded = expandConfigLikePath(trimmed)
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func defaultFileScanRoots() -> [String] {
        let home = NSHomeDirectory()
        let defaults = ["Desktop", "Documents", "Downloads"]
        return defaults.map { URL(fileURLWithPath: home).appendingPathComponent($0).standardizedFileURL.path }
    }

    private func isRiskyRoot(_ path: String) -> Bool {
        let riskyRoots = ["/", "/System", "/Library", "/private"]
        return riskyRoots.contains(where: { $0 == path })
    }

    private func pathContains(_ candidateRoot: String, _ path: String) -> Bool {
        let root = URL(fileURLWithPath: candidateRoot).standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        if root == target {
            return true
        }
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        return target.hasPrefix(normalizedRoot)
    }

    private func expandConfigLikePath(_ value: String) -> String {
        let home = NSHomeDirectory()
        if value == "~" {
            return home
        }
        if value.hasPrefix("~/") {
            let relative = value.dropFirst(2)
            return home + "/" + relative
        }
        if value.hasPrefix("/") {
            return value
        }
        return home + "/" + value
    }

    private static let defaultConfigContents = """
# lumio configuration
# Generated on first launch. Edit values and press Cmd+Shift+; to reload.

# Backend indexing
app_scan_roots=/Applications,/System/Applications,/System/Applications/Utilities,/System/Library/CoreServices/Applications,/System/Library/CoreServices/Finder.app/Contents/Applications
app_scan_depth=3
app_exclude_paths=
app_exclude_names=
file_scan_roots=Desktop,Documents,Downloads
file_scan_extra_roots=
file_scan_depth=4
file_scan_limit=8000
file_exclude_paths=
ignored_patterns_sample=
# File ignore patterns. Gitignore-style path globs: *, **, ?, [abc].
# Format: ignored_patterns_<group>=Pattern1|Pattern2|Pattern3
# macOS/Linux usually use ~/... or /... ; on Windows, C:\\... is the safest documented form and ~ expands to your home dir.
# ignored_patterns_browser=~/AppData/Local/BraveSoftware/**/*.log|~/AppData/Local/Google/Chrome/**/*.tmp
# ignored_patterns_sqlite=~/Documents/git/project/**/*.db-wal|~/Documents/git/project/**/*.db-shm
# ignored_patterns_temp=~/Downloads/*.tmp|~/Downloads/**/*.part
lazy_indexing_enabled=true
# OCR tab: search text inside images and PDFs under file_scan_roots.
# false also deletes the stored text. content_index_limit = most files read, newest first.
content_index_enabled=true
content_index_limit=3000
backend_log_level=error
launch_at_login=true
# Translator languages (tr" / tw"), 1-5 codes. Choices: en,vi,fr,ja,ko,zh-Hans,zh-Hant,es,de,it,pt,ru,th,id,hi,ar
translation_languages=vi,en,fr
skip_dir_names=node_modules,target,build,dist,library,applications,old firefox data,deriveddata,pods,vendor,out,coverage,tmp,cache,venv

# Search aliases (apps + System Settings). Format: alias_<keyword>=Term1|Term2|Term3
alias_note=Notion|Obsidian|Notes|Apple Notes|Bear|Logseq
alias_code=Visual Studio Code|VSCode|Cursor|Windsurf|IntelliJ IDEA|PyCharm|WebStorm|Neovim|Xcode|Zed
alias_term=Terminal|iTerm|iTerm2|Ghostty|WezTerm|Alacritty|Kitty|Warp
alias_chat=Slack|Discord|Telegram|Messages
alias_music=Spotify|Apple Music|Music
alias_brow=Safari|Arc|Google Chrome|Chrome|Firefox|Brave
"""

    private static func loadThemeSettings(from data: Data?) -> ThemeSettings {
        guard let data else { return .default }
        // Older blobs carry theme keys too; JSONDecoder ignores keys it doesn't know.
        return (try? JSONDecoder().decode(ThemeSettings.self, from: data)) ?? .default
    }

    private func applyLaunchAtLoginSetting() -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if settings.launchAtLogin {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                return true
            } catch {
                return false
            }
        }

        return false
    }
}
