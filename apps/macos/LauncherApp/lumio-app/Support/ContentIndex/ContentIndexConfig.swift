import Foundation

/// What the content index reads, taken from `~/.lumio/config`. It walks the same folders as
/// the file index (`file_scan_roots`, `file_scan_extra_roots`, minus `file_exclude_paths` and
/// `skip_dir_names`), plus two keys of its own:
///
///     content_index_enabled=true    # false = no OCR / text search, and the stored text is deleted
///     content_index_limit=3000      # most files whose text is kept (newest first)
nonisolated struct ContentIndexConfig: Equatable, Sendable {
    static let enabledKey = "content_index_enabled"
    static let limitKey = "content_index_limit"
    static let defaultLimit = 3000
    static let limitRange = 100...20_000
    static let defaultDepth = 4
    static let depthRange = 1...12
    static let defaultRootNames = ["Desktop", "Documents", "Downloads"]
    static let defaultSkipDirNames = [
        "node_modules", "target", "build", "dist", "library", "applications", "old firefox data",
        "deriveddata", "pods", "vendor", "out", "coverage", "tmp", "cache", "venv",
    ]
    /// Roots too broad to OCR everything under them.
    private static let refusedRoots: Set<String> = ["/", "/System", "/Library", "/private", "/Users", "/Applications"]

    var enabled = true
    var roots: [String] = []
    var excludedPaths: [String] = []
    var skipDirNames: Set<String> = Set(defaultSkipDirNames)
    var depth = defaultDepth
    var limit = defaultLimit

    /// Main actor: `ConfigFileLines` lives there in the app target.
    @MainActor
    static func from(keyValues: [String: String], home: String) -> ContentIndexConfig {
        var config = ContentIndexConfig()
        config.roots = defaultRootNames.map { resolve($0, home: home) }

        if let raw = keyValues[enabledKey], let value = parseBool(raw) {
            config.enabled = value
        }
        if let raw = keyValues[limitKey], let value = Int(raw.trimmingCharacters(in: .whitespaces)) {
            config.limit = min(max(value, limitRange.lowerBound), limitRange.upperBound)
        }
        if let raw = keyValues["file_scan_depth"], let value = Int(raw.trimmingCharacters(in: .whitespaces)) {
            config.depth = min(max(value, depthRange.lowerBound), depthRange.upperBound)
        }
        if let raw = keyValues["file_scan_roots"] {
            let parsed = ConfigFileLines.parseList(raw).map { resolve($0, home: home) }
            if !parsed.isEmpty { config.roots = parsed }
        }
        if let raw = keyValues["file_scan_extra_roots"] {
            config.roots += ConfigFileLines.parseList(raw).map { resolve($0, home: home) }
        }
        if let raw = keyValues["file_exclude_paths"] {
            config.excludedPaths = ConfigFileLines.parseList(raw).map { resolve($0, home: home) }
        }
        if let raw = keyValues["skip_dir_names"] {
            config.skipDirNames = Set(ConfigFileLines.parseList(raw).map { $0.lowercased() })
        }

        var seen = Set<String>()
        config.roots = config.roots.filter { !refusedRoots.contains($0) && seen.insert($0).inserted }
        return config
    }

    /// `Documents` → `<home>/Documents`, `~/x` → `<home>/x`, absolute paths unchanged.
    static func resolve(_ value: String, home: String) -> String {
        let path: String
        if value == "~" {
            path = home
        } else if value.hasPrefix("~/") {
            path = home + "/" + value.dropFirst(2)
        } else if value.hasPrefix("/") {
            path = value
        } else {
            path = home + "/" + value
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// True when `path` is an excluded folder or inside one.
    func isExcluded(_ path: String) -> Bool {
        excludedPaths.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "yes", "on": true
        case "false", "0", "no", "off": false
        default: nil
        }
    }
}
