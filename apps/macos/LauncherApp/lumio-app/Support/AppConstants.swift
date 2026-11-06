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
        case AppConstants.Launcher.Command.emptyTrash:
            return "trash.slash"
        case AppConstants.Launcher.Command.help:
            return "questionmark.circle"
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
    enum Launcher {

        enum Command {
            static let kill = "kill"
            static let emptyTrash = "emptytrash"
            static let help = "help"
        }



        // Query prefixes the core still understands. The launcher no longer takes them
        // typed: each is a tab (SpotlightKind.toolTabs); `lumio <mode>` still sends them.
        enum QueryPrefix {
            static let apps = "a\""
            static let files = "f\""
            static let folders = "d\""
            static let clipboard = "c\""
            // Copied images (see LauncherClipboardImageFeature).
            static let clipboardImage = "ci\""
            // Dictionary prefix (handled in LauncherView+Translation).
            static let translateWord = "tw\""
            // Translate text with Apple Translation (Spotlight launcher only, see TextTranslator).
            static let translate = "tr\""
            // Live process finder (handled in LauncherView+Process): fuzzy over
            // running processes, kill / copy-PID / measure-CPU from the results.
            static let process = "ps\""

        }



        enum WebURL {
            /// Max previously-opened URLs suggested for the current query.
            static let recentLimit = 5
        }

        /// `ps"` process-finder constants. Logic lives in `LauncherProcessFeature`.
        enum Process {
            /// Row cap: enough to scroll, few enough to render instantly
            /// (mirrors linows `PROC_RESULT_LIMIT`).
            static let resultLimit = 50
        }

        enum Finder {
            static let appName = "finder"
            static let appPath = "/System/Library/CoreServices/Finder.app"
            static var pinnedResultID: String {
                "app:\(appPath.lowercased())"
            }
            static let minPrefixMatchLength = 3
        }

        /// Preferred tools: Cmd+E and Cmd+T act through the tools a user named
        /// in their config. See `specs/preferred-tools.md`.
        enum Tools {
            static let editAction = "edit"
            static let terminalAction = "terminal"
            static let launchFailedBanner = "Could not start"
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
            /// The `kind` column's values. Must match core/storage.
            static let textKind = "text"
            static let imageKind = "image"
            // How many clips history keeps. `maxEntries` is the default/fallback used
            // when `clipboard_history_limit` in ~/.lumio/config is absent or out of the
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
        }

        /// The `ci"` history. Shares rows and storage with Clipboard above;
        /// only the capture limits and the labels differ.
        nonisolated enum ClipboardImage {
            /// The fallback when `clipboard_image_limit` in ~/.lumio/config is
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
            static let returnKey: UInt16 = 36
            static let tab: UInt16 = 48
            static let escape: UInt16 = 53
            static let keypadEnter: UInt16 = 76
            static let arrowUp: UInt16 = 126
            static let arrowDown: UInt16 = 125
        }


        /// Catalog order is the whole shortcut mapping: ⌘N selects the Nth entry
        /// (see `onSelectCommandByIndex`), so the number in each title is
        /// derived rather than written, and reordering this list is enough.
        private static let commandDefinitions: [(id: String, detail: String, placeholder: String)] = [
            (Command.kill, "Force kill app or process by name, PID, or port", "Type a name, PID, or port"),
            (Command.emptyTrash, "Empty the Trash (asks first)", "⏎ empty, Esc cancel"),
            (Command.help, "Tabs, commands and shortcuts", "Filter"),
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

    }

    enum ThemeUI {
        static let fontSize: CGFloat = 13
        static let labelWidth: CGFloat = 150
    }

    enum FileScan {
        static let minDepth = 1
        static let maxDepth = 12
        static let minLimit = 500
        static let maxLimit = 50_000
    }
}
