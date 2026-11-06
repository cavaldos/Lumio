import Foundation

enum LauncherPinnedLookupScope: Equatable {
    case unscoped
    case apps
    case files
    case folders
    case disabled
}

enum LauncherSearchLogic {
    static func pinnedLookupScope(for query: String) -> LauncherPinnedLookupScope {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.regex)
            || normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.clipboard)
            || normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.recent)
        {
            // Recent (rc") is engine-ranked by recency; suppress quick-folder and
            // Finder pinned injection so they don't pollute the recent list.
            return .disabled
        }
        if normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.apps) {
            return .apps
        }
        if normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.files) {
            return .files
        }
        if normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.folders) {
            return .folders
        }
        return .unscoped
    }

    static func normalizedPinnedLookupQuery(
        for query: String,
        scope: LauncherPinnedLookupScope
    ) -> String? {
        var normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if scope == .apps, normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.apps) {
            normalized = String(normalized.dropFirst(AppConstants.Launcher.QueryPrefix.apps.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if scope == .files, normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.files) {
            normalized = String(normalized.dropFirst(AppConstants.Launcher.QueryPrefix.files.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if scope == .folders, normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.folders) {
            normalized = String(normalized.dropFirst(AppConstants.Launcher.QueryPrefix.folders.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if scope == .disabled || normalized.isEmpty {
            return nil
        }

        return normalized
    }

    static func shouldInjectFinder(
        normalizedQuery: String?,
        scope: LauncherPinnedLookupScope
    ) -> Bool {
        guard scope == .unscoped || scope == .apps else { return false }
        guard let normalized = normalizedQuery else { return false }

        let finderName = AppConstants.Launcher.Finder.appName
        return normalized.contains(finderName)
            || (finderName.hasPrefix(normalized)
                && normalized.count >= AppConstants.Launcher.Finder.minPrefixMatchLength)
    }

}
