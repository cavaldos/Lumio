//
//  SpotlightFiles.swift
//  lumio-app
//
//  File search across the whole Mac, from the Spotlight index macOS already keeps. Lumio's
//  own index (Rust core) covers Desktop / Documents / Downloads a few levels deep with fuzzy
//  matching; this fills in everything else, like Fluent Search's whole-drive file search,
//  and powers the file tags (`downloads` ⇥, `pdf` ⇥, a folder path ⇥).
//
//  Matching is by name: every typed word must appear in the file name (any order, case and
//  accent-insensitive). Ranked by how well the name matches, then by how recently the file
//  was used. The queries run on `SpotlightQueue`, never on Swift's task pool (see there why).
//

import CoreServices
import Foundation

nonisolated struct FileHit: Equatable, Sendable {
    let path: String
    let name: String
    let date: Date?
    let isFolder: Bool
}

/// Plugged-in drives (external SSDs, USB sticks, SD cards, other partitions) that file search
/// covers next to the home folder. Each drive's own Spotlight index answers, so there is
/// nothing to build and no file-count limit; a drive Spotlight does not index (some network
/// or freshly formatted disks) simply returns nothing.
nonisolated enum ExternalDrives {
    static let configKey = "search_external_drives"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabled = true
    nonisolated(unsafe) private static var cache: (at: Date, volumes: [(name: String, path: String)])?

    /// Set from the config (`search_external_drives`, default on) when the launcher opens.
    static var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    /// Mounted local volumes other than the startup disk, e.g. ("T7", "/Volumes/T7").
    static func mounted() -> [(name: String, path: String)] {
        lock.lock()
        if let cache, Date().timeIntervalSince(cache.at) < 5 { lock.unlock(); return cache.volumes }
        lock.unlock()
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsBrowsableKey, .volumeNameKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes: [(String, String)] = urls.compactMap { url in
            guard url.path.hasPrefix("/Volumes/"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true, values.volumeIsBrowsable == true,
                  values.volumeIsRootFileSystem != true
            else { return nil }
            // The startup disk also appears under /Volumes as a link to "/".
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { return nil }
            return (values.volumeName ?? url.lastPathComponent, url.path)
        }
        lock.lock(); cache = (Date(), volumes); lock.unlock()
        return volumes
    }

    /// Paths to add to a whole-Mac search (empty when turned off or nothing is plugged in).
    static var searchPaths: [String] { isEnabled ? mounted().map(\.path) : [] }
}

nonisolated enum SpotlightFiles {
    /// Files matching `term` within `scope` (nil = the home folder, all kinds).
    /// Empty term with a scope: the scope's most recent files (what a file tag shows on entry).
    /// Extensions recognised when typed as part of the text (`topper guild.psd`, `invoice .pdf`).
    static let knownExtensions: Set<String> = [
        "psd", "psb", "psdt", "ai", "eps", "indd", "fig", "sketch", "xd", "afdesign", "afphoto",
        "png", "jpg", "jpeg", "heic", "gif", "webp", "svg", "tif", "tiff", "bmp", "raw", "cr2", "nef", "arw", "dng",
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "prproj", "aep", "drp",
        "mp3", "wav", "m4a", "flac", "aiff",
        "pdf", "doc", "docx", "pages", "txt", "rtf", "md", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key",
        "zip", "rar", "7z", "dmg", "pkg", "otf", "ttf",
        "json", "html", "css", "js", "ts", "py", "swift", "sh",
    ]

    /// Source code, configuration and build output. Still searchable, but ranked below every
    /// other file: a project folder holds thousands of them and they are rarely what a search
    /// from the launcher is after. (Fluent Search has a "prioritized extensions" list for the
    /// same reason.) Picking one teaches Lumio to offer it first for that text anyway.
    static let defaultLowPriorityExtensions: Set<String> = [
        "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs", "map", "json", "jsonc", "lock", "yml", "yaml",
        "toml", "xml", "plist", "css", "scss", "sass", "less", "html", "htm", "vue", "svelte", "md", "mdx",
        "py", "rb", "go", "rs", "swift", "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "cs", "php",
        "sh", "bash", "zsh", "log", "pak", "snap", "tsbuildinfo", "gitignore", "env", "cfg", "ini", "conf",
        "sql", "db", "bin", "dat", "o", "a", "dylib", "node", "wasm", "pyc", "class",
    ]

    static let lowPriorityConfigKey = "low_priority_extensions"

    /// The list in use: the default, or `low_priority_extensions=ts,js,json` from the config
    /// (an empty value turns the demotion off).
    nonisolated(unsafe) private(set) static var lowPriorityExtensions = defaultLowPriorityExtensions

    static func setLowPriority(fromConfig value: String?) {
        guard let value else {
            lowPriorityExtensions = defaultLowPriorityExtensions
            return
        }
        lowPriorityExtensions = Set(value.split(whereSeparator: { ", ;|".contains($0) }).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        }.filter { !$0.isEmpty })
    }

    static func isLowPriority(_ name: String) -> Bool {
        lowPriorityExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Splits the typed text into name words and file extensions:
    /// "topper guild.psd" → words ["topper", "guild"], extensions ["psd"]. Only known
    /// extensions count, so "v2.final" stays a word.
    static func parse(_ term: String) -> (words: [String], extensions: [String]) {
        var words: [String] = []
        var extensions: [String] = []
        for raw in term.lowercased().split(separator: " ").map(String.init) {
            if let dot = raw.lastIndex(of: "."), knownExtensions.contains(String(raw[raw.index(after: dot)...])) {
                extensions.append(String(raw[raw.index(after: dot)...]))
                let stem = clean(String(raw[..<dot]))
                if !stem.isEmpty { words.append(stem) }
            } else {
                let word = clean(raw)
                if !word.isEmpty { words.append(word) }
            }
        }
        return (words, extensions)
    }

    /// Files matching `term`, from the Spotlight queue. Empty when the calling task is
    /// cancelled first (the text changed).
    static func search(term: String, scope: FileScope?, limit: Int) async -> [FileHit] {
        await SpotlightQueue.run(skipped: []) { isCancelled in
            blockingSearch(term: term, scope: scope, limit: limit, isCancelled: isCancelled)
        }
    }

    /// One or two Spotlight queries, each blocking until Spotlight answers. Only ever called
    /// on `SpotlightQueue`.
    private static func blockingSearch(
        term: String, scope: FileScope?, limit: Int, isCancelled: () -> Bool
    ) -> [FileHit] {
        let (words, typedExtensions) = parse(term)
        let scope = scope ?? FileScope()
        // No folder asked for: the home folder plus any plugged-in drives.
        let folders = scope.folders.isEmpty ? [NSHomeDirectory()] + ExternalDrives.searchPaths : scope.folders
        let insideUserFolders = scope.folders.isEmpty

        // `content` tag: the words must appear inside the document (word starts), not in its name.
        if scope.contentSearch, words.isEmpty { return [] }
        var conditions: [String] = words.map {
            scope.contentSearch ? "kMDItemTextContent == \"\($0)*\"cd" : "kMDItemFSName == \"*\($0)*\"cd"
        }
        var kinds: [String] = scope.extensions.map { "kMDItemFSName == \"*.\(clean($0))\"c" }
        kinds += scope.contentTypes.map { "kMDItemContentTypeTree == \"\(clean($0))\"" }
        if !kinds.isEmpty { conditions.append("(" + kinds.joined(separator: " || ") + ")") }
        if !typedExtensions.isEmpty {
            let typed = typedExtensions.map { "kMDItemFSName == \"*.\($0)\"c" }
            conditions.append("(" + typed.joined(separator: " || ") + ")")
        }
        if scope.foldersOnly { conditions.append("kMDItemContentType == \"public.folder\"") }
        if scope.filesOnly { conditions.append("kMDItemContentType != \"public.folder\"") }

        // Recent inside one folder: opened, added or changed. Across the whole home folder only
        // "opened by you" (kMDItemLastUsedDate): app data changes constantly and would crowd it out.
        let recent = insideUserFolders
            ? "kMDItemLastUsedDate >= $time.today(-60)"
            : "(kMDItemLastUsedDate >= $time.today(-60) || kMDItemDateAdded >= $time.today(-60)"
                + " || kMDItemContentModificationDate >= $time.today(-60))"
        let browsing = words.isEmpty && typedExtensions.isEmpty
        if browsing || scope.recentOnly { conditions.append(recent) }
        if conditions.isEmpty { conditions.append("kMDItemFSName == \"*\"") }

        var hits = run(conditions.joined(separator: " && "), scopes: folders, max: 250)
        // Typed on meanwhile: nobody will see this list, so don't query Spotlight again for it.
        if isCancelled() { return [] }
        // A folder with nothing new in 60 days: show its newest files anyway.
        if browsing, hits.isEmpty, !scope.recentOnly, !scope.folders.isEmpty {
            hits = run((conditions.dropLast() + ["kMDItemFSName == \"*\""]).joined(separator: " && "),
                       scopes: folders, max: 250)
        }

        // Spotlight hands back an arbitrary 250 when there are more: ask again for just the
        // recently changed ones, so this week's files are never the ones left out.
        if !browsing, hits.count >= 250 {
            let recentOnly = conditions + ["(kMDItemContentModificationDate >= $time.today(-45)"
                + " || kMDItemLastUsedDate >= $time.today(-45))"]
            let known = Set(hits.map(\.path))
            hits += run(recentOnly.joined(separator: " && "), scopes: folders, max: 250)
                .filter { !known.contains($0.path) }
        }

        let home = NSHomeDirectory()
        let needle = words.joined(separator: " ")
        return hits
            .filter { isUserFile($0.path, home: home, strict: insideUserFolders) }
            // Code and config files last (unless an extension was asked for, e.g. "align.ts").
            .map { hit in
                (hit, nameScore(hit.name.lowercased(), needle: needle, words: words)
                    - (typedExtensions.isEmpty && scope.extensions.isEmpty && isLowPriority(hit.name) ? 10 : 0))
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return (lhs.0.date ?? .distantPast) > (rhs.0.date ?? .distantPast)
            }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Spotlight

    /// Dates and type come back with the results when declared as sorting attributes (no
    /// per-file round trip); the path is not served that way and is read per file.
    private static var sortingAttributes: CFArray {
        [kMDItemLastUsedDate, kMDItemDateAdded, kMDItemContentModificationDate, kMDItemContentType] as CFArray
    }

    /// Blocks until Spotlight answers: only on `SpotlightQueue`.
    private static func run(_ text: String, scopes: [String], max: Int) -> [FileHit] {
        guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, sortingAttributes)
        else { return [] }
        MDQuerySetSearchScope(query, scopes as CFArray, 0)
        MDQuerySetMaxCount(query, max)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        defer { MDQueryStop(query) }

        func value(_ attribute: CFString, _ index: CFIndex) -> AnyObject? {
            guard let raw = MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        }

        var out: [FileHit] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let dates = [kMDItemLastUsedDate, kMDItemDateAdded, kMDItemContentModificationDate]
                .compactMap { value($0, index) as? Date }
            out.append(FileHit(
                path: path, name: (path as NSString).lastPathComponent,
                date: dates.max(),
                isFolder: (value(kMDItemContentType, index) as? String) == "public.folder"
            ))
        }
        return out
    }

    // MARK: - Ranking / filtering

    /// Name starts with the text > a word starts with it > contains it.
    static func nameScore(_ name: String, needle: String, words: [String]) -> Int {
        guard !needle.isEmpty else { return 0 }
        let stem = (name as NSString).deletingPathExtension
        if stem == needle { return 5 }
        if name.hasPrefix(needle) { return 4 }
        let separators = CharacterSet(charactersIn: " -_.()[]")
        let nameWords = name.components(separatedBy: separators).filter { !$0.isEmpty }
        if words.allSatisfy({ word in nameWords.contains { $0.hasPrefix(word) } }) { return 3 }
        if name.contains(needle) { return 2 }
        return 1
    }

    /// No app data or bundle innards. `strict` (searching the whole home folder) also skips
    /// ~/Library and hidden folders; an explicit folder tag is searched as asked.
    static func isUserFile(_ path: String, home: String, strict: Bool) -> Bool {
        let bundleExts = [".app/", ".photoslibrary/", ".bundle/", ".xcodeproj/", ".pkg/", ".framework/",
                          ".xcassets/", ".lproj/", "/node_modules/", "/.git/"]
        if bundleExts.contains(where: { path.contains($0) }) { return false }
        guard strict else { return true }
        // A plugged-in drive: everything on it that isn't hidden.
        if path.hasPrefix("/Volumes/") {
            return !path.split(separator: "/").contains { $0.hasPrefix(".") || $0.hasPrefix("$") }
        }
        guard path.hasPrefix(home + "/") else { return false }
        let relative = path.dropFirst(home.count + 1)
        // iCloud Drive lives under ~/Library but is the user's files.
        if relative.hasPrefix("Library/Mobile Documents/com~apple~CloudDocs/") { return true }
        if relative.hasPrefix("Library/") { return false }
        return !relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Spotlight query strings: drop the characters that would break out of `"…"`.
    private static func clean(_ text: String) -> String {
        text.filter { $0 != "\"" && $0 != "*" && $0 != "\\" && $0 != "?" }
    }
}
