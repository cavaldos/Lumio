import Foundation

/// Hides an app from launcher results by adding it to `app_exclude_names` in the config file.
enum AppExcludeWriter {
    enum Result {
        case added
        case alreadyExcluded
        case writeFailed
    }

    static func append(_ appName: String) -> Result {
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .writeFailed }

        let path = URL(fileURLWithPath: ConfigPathResolver.resolvedPath())
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else {
            return .writeFailed
        }

        var lines = ConfigFileLines.parse(raw)
        let values = ConfigFileLines.keyValues(raw)
        var names = ConfigFileLines.parseList(values[key] ?? "")

        // Normalised, or `Safari`, `safari` and `Safari.app` pile up as three
        // entries the core treats as one.
        let normalizedName = normalize(trimmedName)
        guard !names.contains(where: { normalize($0) == normalizedName }) else {
            return .alreadyExcluded
        }

        names.append(trimmedName)
        ConfigFileLines.upsert(&lines, key: key, value: ConfigFileLines.renderList(names))

        do {
            try ConfigFileLines.render(lines).write(to: path, atomically: true, encoding: .utf8)
            return .added
        } catch {
            return .writeFailed
        }
    }

    /// Mirrors `normalize_app_name` in `core/engine/src/platform/macos/apps.rs`.
    private static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutSuffix = trimmed.hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
        return withoutSuffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let key = "app_exclude_names"
}
