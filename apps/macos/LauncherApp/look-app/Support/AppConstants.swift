import Foundation
import CoreGraphics

struct AppCommand: Identifiable {
    let id: String
    let title: String
    let detail: String
    let placeholder: String

    var symbolName: String {
        switch id {
        case AppConstants.Launcher.Command.kill:
            return "xmark.circle"
        case AppConstants.Launcher.Command.speed:
            return "speedometer"
        default:
            return "terminal"
        }
    }
}

struct QuickFolderDefinition {
    /// Where a quick folder lives. Most are under the user's home directory
    /// (`.home("Desktop")`); a few are fixed system locations outside home
    /// (`.absolute("/Applications")`).
    enum Location {
        case home(String)
        case absolute(String)
    }

    let title: String
    let location: Location
    var subtitle: String? = nil

    /// Resolves to a concrete filesystem path. Home-relative entries are joined
    /// onto `homeDirectory`; absolute entries are used verbatim.
    func resolvedPath(homeDirectory: String) -> String {
        switch location {
        case .home(let relativePath):
            return URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent(relativePath)
                .path
        case .absolute(let path):
            return path
        }
    }
}

enum AppConstants {
    /// Resting radii, scaled by the Corner Radius setting through
    /// `ThemeStore`. A radius that follows an element's geometry instead - an
    /// icon mask, a circular badge, a heatmap cell - is not one of these.
    enum Radius {
        static let panel: CGFloat = 16
        static let tile: CGFloat = 12
        static let bar: CGFloat = 10
        static let control: CGFloat = 8
        static let chip: CGFloat = 6
        static let micro: CGFloat = 4
    }

    enum Launcher {
        /// Search field placeholder shown in normal (non-command) mode.
        static let searchPlaceholder = "Type whatever you want"
        /// Search field placeholder shown in command mode when no command is active.
        static let commandModePlaceholder = "Choose a command with Tab"

        enum Command {
            static let kill = "kill"
            static let speed = "speed"
        }



        enum QueryPrefix {
            static let apps = "a\""
            static let files = "f\""
            static let folders = "d\""
            static let regex = "r\""
            static let clipboard = "c\""
            // Copied images (see LauncherClipboardImageFeature).
            static let clipboardImage = "ci\""
            // Recent files/folders, newest-activity first. Handled engine-side
            // (needs last_used/fs_modified timestamps); the app just sends it
            // through search and suppresses pinned injection (see LauncherSearchLogic).
            static let recent = "rc\""
            // Dictionary prefix (handled in LauncherView+Translation).
            static let translateWord = "tw\""
            // Live process finder (handled in LauncherView+Process): fuzzy over
            // running processes, kill / copy-PID / measure-CPU from the results.
            static let process = "ps\""

            // Typing a lone `"` opens the prefix-discovery menu (see
            // PrefixSuggestion.all / LauncherView.isPrefixSuggestionQuery).
            static let discovery = "\""
        }

        // Canonical list of query prefixes, with a usage hint and a description.
        // Single source of truth for the prefix-discovery menu (type `"`), the help
        // screen's "Query modes" section, and the Settings → Shortcuts panel, so
        // the three can't drift apart.
        enum PrefixSuggestion {
            // Synthetic result id prefix; lets the row view and open handler tell a
            // discovery suggestion apart from a real candidate.
            static let resultIDPrefix = "prefixhint:"

            struct Entry: Identifiable {
                let prefix: String
                let argHint: String
                let description: String
                /// Whether this entry appears in the live `"` discovery menu.
                /// The `"` entry itself is documented in the static lists but
                /// hidden from the menu it opens (see `menuEntries`).
                var listedInMenu: Bool = true
                var id: String { prefix }
                /// What the help/shortcuts lists show, e.g. `a"word` (or just `"`).
                var displayWithArg: String { prefix + argHint }
            }

            /// Entries shown in the live discovery menu (excludes `"` itself).
            static var menuEntries: [Entry] { all.filter(\.listedInMenu) }

            /// Discovery entries narrowed by `filter` - the text typed after the
            /// leading `"`. Case-insensitive substring match against the prefix,
            /// its display form, and the description, so `"folder` finds `d"` by
            /// intent rather than only by the cryptic prefix letter. An empty
            /// filter returns the full menu.
            static func menuEntries(matching filter: String) -> [Entry] {
                let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !needle.isEmpty else { return menuEntries }
                return menuEntries.filter {
                    $0.prefix.lowercased().contains(needle)
                        || $0.displayWithArg.lowercased().contains(needle)
                        || $0.description.lowercased().contains(needle)
                }
            }

            static let all: [Entry] = [
                Entry(
                    prefix: QueryPrefix.discovery, argHint: "",
                    description: "Browse all prefixes", listedInMenu: false),
                Entry(prefix: QueryPrefix.apps, argHint: "word", description: "Apps only"),
                Entry(prefix: QueryPrefix.files, argHint: "word", description: "Files only"),
                Entry(prefix: QueryPrefix.folders, argHint: "word", description: "Folders only"),
                Entry(
                    prefix: QueryPrefix.recent, argHint: "word",
                    description: "Recent files/folders, newest first (optional filter)"),
                Entry(prefix: QueryPrefix.regex, argHint: "pattern", description: "Regex search"),
                Entry(
                    prefix: QueryPrefix.clipboard, argHint: "word",
                    description: "Clipboard history search (recent text clips)"),
                Entry(
                    prefix: QueryPrefix.clipboardImage, argHint: "word",
                    description: "Copied images, newest first"),
                Entry(
                    prefix: QueryPrefix.translateWord, argHint: "word",
                    description: "Lookup panel with definitions"),
                Entry(
                    prefix: QueryPrefix.process, argHint: "word",
                    description: "Find & kill running processes"),
            ]

            /// Recovers the query prefix encoded in a discovery-suggestion result
            /// id, or nil when `resultID` isn't a discovery suggestion.
            static func prefix(fromResultID resultID: String) -> String? {
                guard resultID.hasPrefix(resultIDPrefix) else { return nil }
                return String(resultID.dropFirst(resultIDPrefix.count))
            }
        }


        // Synthesized "Open <url>" row for a URL-like query (issue #232). Told
        // apart from real candidates by id; the resolved URL is encoded in it.
        enum WebURL {
            static let resultIDPrefix = "weburl:"
            // Max previously-opened URLs suggested for the current query.
            static let recentLimit = 5
            // Row subtitles: the live-classified row vs a row from history.
            static let openSubtitle = "Open in browser"
            static let recentSubtitle = "Recently opened"

            /// Encodes the resolved URL into a synthetic result id.
            static func resultID(url: String) -> String {
                "\(resultIDPrefix)\(url)"
            }

            /// Recovers the resolved URL encoded in a result id, or nil.
            static func url(fromResultID resultID: String) -> String? {
                guard resultID.hasPrefix(resultIDPrefix) else { return nil }
                return String(resultID.dropFirst(resultIDPrefix.count))
            }
        }

        /// `ps"` process-finder constants. Logic lives in `LauncherProcessFeature`.
        enum Process {
            static let resultIDPrefix = "process:"
            /// Row cap: enough to scroll, few enough to render instantly
            /// (mirrors linows `PROC_RESULT_LIMIT`).
            static let resultLimit = 50
            /// Synthetic path so the row isn't treated as a filesystem target.
            static let resultPath = "look://process"
        }

        enum Finder {
            static let appName = "finder"
            static let appPath = "/System/Library/CoreServices/Finder.app"
            static var pinnedResultID: String {
                "app:\(appPath.lowercased())"
            }
            static let pinnedSubtitle = "Pinned system app"
            static let pinnedScore = 999_999
            static let minPrefixMatchLength = 3
            static let cannotRevealBanner = "Cannot reveal this target in Finder"
        }

        /// The Cmd+K action menu: everything you can do to the selected row,
        /// in one place, instead of scattered across Cmd+F / Cmd+C / Cmd+P.
        enum ActionMenu {
            static let openHint = "⌘K / ⌃K actions"
            static let moveHint = "⌘J / ⌘K or ⌃J / ⌃K move  •  ⏎ run"
            static let runHint = "↵"
            static let maxHeight: CGFloat = 240
            static let rowVerticalPadding: CGFloat = 7
            static let rowHorizontalPadding: CGFloat = 10
            static let shadowRadius: CGFloat = 14
        }

        /// Preferred tools: Cmd+E and Cmd+T act through the tools a user named
        /// in their config. See `specs/preferred-tools.md`.
        enum Tools {
            static let editAction = "edit"
            static let terminalAction = "terminal"
            static let revealAction = "reveal"
            static let launchFailedBanner = "Could not start"
            /// Shown when no `file_manager` is declared, which is the default.
            static let systemFileManagerName = "Finder"
            static let bannerDuration: TimeInterval = 2.4
            /// Long enough for the terminal to have made its new window, so
            /// activating raises that one and not the window it already had.
            static let activationSettleNanoseconds: UInt64 = 350_000_000
            /// A terminal that was not running yet has to start first.
            static let activationPollNanoseconds: UInt64 = 200_000_000
            static let activationPollAttempts = 8
        }

        enum QuickFolder {
            static let idPrefix = "quickfolder:"
            static let pinnedSubtitle = "Pinned home folder"
            static let minPrefixMatchLength = 2
            static let absoluteFolderSubtitle = "Pinned folder"
            static let entries: [QuickFolderDefinition] = [
                QuickFolderDefinition(title: "Desktop", location: .home("Desktop")),
                QuickFolderDefinition(title: "Documents", location: .home("Documents")),
                QuickFolderDefinition(title: "Downloads", location: .home("Downloads")),
                QuickFolderDefinition(title: "Pictures", location: .home("Pictures")),
                // macOS names this folder "Movies" (Windows calls the equivalent "Videos");
                // each platform's QuickFolder uses the OS-native folder name so typing what
                // the user sees in Finder/Explorer pins it.
                QuickFolderDefinition(title: "Movies", location: .home("Movies")),
                QuickFolderDefinition(title: "Music", location: .home("Music")),
                // /Applications is a system folder outside home - the folder indexer
                // only walks Desktop/Documents/Downloads, so pin it here to make it
                // reachable. .app bundles inside it stay app candidates, not folders.
                QuickFolderDefinition(
                    title: "Applications",
                    location: .absolute("/Applications"),
                    subtitle: absoluteFolderSubtitle
                ),
                // ~/.Trash is a real directory, so it opens in Finder like any
                // other quick folder. Typing "trash" pins it; ⌘D empties it.
                QuickFolderDefinition(
                    title: "Trash", location: .home(".Trash"), subtitle: "Pinned · ⌘D to empty"),
            ]
        }

        /// `nonisolated`: read by the writer that stores a clip off the main
        /// thread.
        nonisolated enum Clipboard {
            static let resultIDPrefix = "clipboard:"
            static let resultPath = "clipboard://history"
            /// The `kind` column's values. Must match core/storage.
            static let textKind = "text"
            static let imageKind = "image"
            // How many clips history keeps. `maxEntries` is the default/fallback used
            // when `clipboard_history_limit` in ~/.look/config is absent or out of the
            // [minEntries, maxEntriesLimit] range. See ClipboardHistoryStore.
            static let maxEntries = 10
            static let minEntries = 10
            static let maxEntriesLimit = 100
            static let historyLimitConfigKey = "clipboard_history_limit"
            static let maxStoredCharacters = 30_000
            /// Row label length; longer clips are elided.
            static let maxTitleCharacters = 80
            static let emptyEntryTitle = "(Empty text)"
            static let foregroundPollInterval: TimeInterval = 0.35
            static let backgroundPollInterval: TimeInterval = 0.9
            static let burstPollInterval: TimeInterval = 0.08
            static let burstSampleCount = 10
            static let copiedBanner = "Copied clipboard item"
            static let deletedBanner = "Clipboard item deleted"
            static let nonFileBanner = "Clipboard items are not files"
            static let copiedBannerDuration = 1.2
            static let infoBannerDuration = 1.1
        }

        /// The `ci"` history. Shares rows and storage with Clipboard above;
        /// only the capture limits and the labels differ.
        nonisolated enum ClipboardImage {
            static let resultIDPrefix = "clipimage:"
            static let resultPath = "clipboard://images"
            /// The fallback when `clipboard_image_limit` in ~/.look/config is
            /// absent or out of range.
            static let maxEntries = 20
            static let minEntries = 5
            static let maxEntriesLimit = 50
            static let limitConfigKey = "clipboard_image_limit"
            /// Past this a paste is not a clip worth keeping a copy of.
            static let maxImageBytes = 20 * 1024 * 1024
            /// Bytes say nothing about what they decode to, at four bytes a
            /// pixel. Clears an 8K screenshot and bounds the decode.
            static let maxPixelCount = 64_000_000
            /// Longest edge of the row thumbnail.
            static let thumbnailMaxPixel: CGFloat = 128
            static let fileExtension = "png"
            /// Core sweeps by hash prefix, so any suffix here is safe.
            static let thumbnailSuffix = ".thumb"
            static let unnamedLabelPrefix = "Image from"
            static let unnamedLabelFallbackSource = "screen"
            static let copiedBanner = "Copied image"
            static let deletedBanner = "Image removed from history"
        }

        enum Help {
            static let commandModeInfoBanner = "Help is available in app list mode"
        }

        /// How long the launcher may stay hidden before the next open returns
        /// to the empty home state. `never` is the opt-out every negative value
        /// normalizes to.
        enum QueryRetention {
            static let configKey = "query_retention_seconds"
            static let defaultSeconds = 5
            static let never = -1
        }

        /// Virtual key codes (`NSEvent.keyCode`). These are physical positions on a
        /// US layout, not characters, so a handler that must follow the printed
        /// letter on other layouts matches `charactersIgnoringModifiers` as well.
        enum KeyCode {
            static let d: UInt16 = 2
            static let f: UInt16 = 3
            static let h: UInt16 = 4
            static let c: UInt16 = 8
            static let e: UInt16 = 14
            static let t: UInt16 = 17
            static let j: UInt16 = 38
            static let k: UInt16 = 40
            static let p: UInt16 = 35
            static let returnKey: UInt16 = 36
            static let tab: UInt16 = 48
            static let escape: UInt16 = 53
            static let slash: UInt16 = 44
            static let keypadEnter: UInt16 = 76
            static let arrowUp: UInt16 = 126
            static let arrowDown: UInt16 = 125
        }

        static let defaultSearchLimit = 40
        static let searchDebounceNanoseconds: UInt64 = 70_000_000
        // Shortest query that triggers debounced suggestion lookups (web search
        // autocomplete, recent URLs). Single characters match too much to be useful.
        static let minSuggestionQueryLength = 2
        static let commandListMaxHeight: CGFloat = 180
        static let commandResultFontSize: CGFloat = 18

        enum Panel {
            static let width: CGFloat = 860
            static let height: CGFloat = 580
        }

        enum RunningAppsStrip {
            static let iconSize: CGFloat = 30
            static let horizontalPadding: CGFloat = 6
            static let verticalPadding: CGFloat = 10
            static let itemGap: CGFloat = 8
            // Slack on each end of the strip to keep the active ring from being clipped.
            static let edgeSlack: CGFloat = 6
            static let maxItems = 9

            static var width: CGFloat { iconSize + horizontalPadding * 2 + edgeSlack }

            /// Cmd-number keys in order of physical ease to press from
            /// the typical Cmd-Space launcher posture: left index/middle
            /// fingers first (1, 2, 3), then right-hand edge (9, 8),
            /// then 4 and 7, and finally the painful centre keys
            /// (6, 5). Used as a *resource* - when the strip has fewer
            /// than 9 icons we only consume the easy keys from the
            /// front of this list, so 5/6/7 only appear in 7+ app
            /// configurations.
            private static let easinessOrder: [Int] = [1, 2, 3, 9, 8, 4, 7, 6, 5]

            /// Returns the Cmd-number keys to assign to a strip of
            /// `total` icons, in left-to-right visual order. We pick the
            /// `total` easiest keys from `easinessOrder` and sort them
            /// ascending so the strip still reads naturally (e.g. for
            /// total=5 → `[1, 2, 3, 8, 9]` instead of `[1, 2, 3, 9, 8]`).
            static func badgeKeys(total: Int) -> [Int] {
                guard total > 0 else { return [] }
                return Array(easinessOrder.prefix(min(total, maxItems))).sorted()
            }

            /// The Cmd-number key shown on the badge of the icon at
            /// `position` (left-to-right, 0-indexed) in a strip of size
            /// `total`. Returns `position + 1` as a fallback for any
            /// out-of-range query.
            static func ergonomicKey(forVisualPosition position: Int, total: Int) -> Int {
                let keys = badgeKeys(total: total)
                guard position >= 0, position < keys.count else { return position + 1 }
                return keys[position]
            }

            /// Inverse of `ergonomicKey`: maps the Cmd-number key the
            /// user pressed (1..9) to the visual position of the icon
            /// they targeted. Returns nil when that key isn't currently
            /// assigned to any icon (e.g. user pressed Cmd+5 with only
            /// 4 running apps).
            static func visualPosition(forKey key: Int, total: Int) -> Int? {
                badgeKeys(total: total).firstIndex(of: key)
            }
        }


        /// Catalog order is the whole shortcut mapping: ⌘N selects the Nth entry
        /// (see `onSelectCommandByIndex`), so the number in each title is
        /// derived rather than written, and reordering this list is enough.
        private static let commandDefinitions: [(id: String, detail: String, placeholder: String)] = [
            (Command.speed, "Measure internet download, upload, and latency", "Measures on open"),
            (Command.kill, "Force kill app or process by name, PID, or port", "Type a name, PID, or port"),
        ]

        static let commandCatalog: [AppCommand] = commandDefinitions.enumerated().map { index, definition in
            AppCommand(
                id: definition.id,
                title: "\(definition.id) (⌘\(index + 1))",
                detail: definition.detail,
                placeholder: definition.placeholder
            )
        }

        /// Commands narrowed by `filter` - the text typed after a leading `:`.
        /// Case-insensitive substring match against the command id and its
        /// description, so `:end` or `:process` both surface `kill`. An empty
        /// filter returns the whole catalog.
        static func commandCatalog(matching filter: String) -> [AppCommand] {
            let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { return commandCatalog }
            return commandCatalog.filter {
                $0.id.lowercased().contains(needle)
                    || $0.detail.lowercased().contains(needle)
            }
        }

        // Command-discovery rows (type `:`). Like PrefixSuggestion, these are
        // Swift-synthesized rows in the main results list, told apart by id;
        // `openSelectedApp` enters the command instead of opening a file.
        enum CommandSuggestion {
            static let resultIDPrefix = "cmdhint:"

            /// Recovers the command id encoded in a discovery-row result id, or nil.
            static func commandID(fromResultID resultID: String) -> String? {
                guard resultID.hasPrefix(resultIDPrefix) else { return nil }
                return String(resultID.dropFirst(resultIDPrefix.count))
            }
        }

        static let normalHint = HintText.Launcher.normal
        static let commandHint = HintText.Launcher.command
        static let killHint = HintText.Launcher.kill
        static let commandEmptyMessage = "Type and press Enter"
    }

    enum ThemeUI {
        static let labelWidth: CGFloat = 150
        static let pickerWidth: CGFloat = 140
        /// Bounds shared by the slider, the config parser and the reload check,
        /// so a value the slider cannot reach is reported rather than clamped.
        static let innerGapRange: ClosedRange<Double> = 0...24
        static let surfaceRadiusRange: ClosedRange<Double> = 0...2.5
        /// Dimming for a control the active theme has taken over, so the value
        /// stays readable while reading as not-yours-to-set.
        static let disabledControlOpacity: Double = 0.4
        /// Appended to a picker entry this OS cannot render, so a value carried
        /// over from a newer machine reads as inert rather than broken.
        static let unsupportedSuffix = "(needs macOS 26)"
    }

    enum FileScan {
        static let minDepth = 1
        static let maxDepth = 12
        static let minLimit = 500
        static let maxLimit = 50_000
    }
}
