//
//  SearchTags.swift
//  lumio-app
//
//  Search tags, like Fluent Search on Windows: type a keyword (`yt`, `g`, `drive`…) and
//  press Tab. The keyword turns into a chip ("YouTube") and whatever you type next is sent
//  straight to that site. While a tag is active the list also shows the site's open browser
//  tabs and recently visited pages, so `drive` + Tab lists your recent Google Drive docs.
//
//  Built-in tags need no setup. Add or override tags in ~/.lumio/config:
//
//    search_tag_yt=YouTube|https://www.youtube.com/results?search_query={query}|youtube.com
//    search_tag_jira=Jira|https://acme.atlassian.net/issues/?jql=text~"{query}"|acme.atlassian.net
//
//  Fields: name | search URL with {query} | domain (optional, used to find matching tabs and
//  history; defaults to the URL's host). An empty value (`search_tag_yt=`) turns a built-in off.
//
//  File tags search files on the whole Mac (Spotlight index) instead of a website:
//
//    downloads ⇥ invoice      files in ~/Downloads named like "invoice"
//    pdf ⇥ / image ⇥          only PDFs / images; empty text = the most recent ones
//    downloads ⇥ pdf ⇥        tags stack: PDFs in Downloads
//    ~/Clients ⇥  (any path)  search inside that folder; Tab on a selected folder row too
//
//    search_tag_work=Work|folder:~/Clients/Work
//    search_tag_raw=RAW photos|ext:cr2,nef,arw,dng
//

import Foundation

nonisolated struct SearchTag: Equatable, Sendable {
    /// What you type before Tab (`yt`). Lowercased, no spaces.
    let keyword: String
    let name: String
    /// Search URL with `{query}` where the text goes. A URL without `{query}` just opens.
    let urlTemplate: String
    /// Host used to match open tabs and history (`youtube.com`). nil = no matching.
    let domain: String?
    /// SF Symbol for the chip and rows.
    var symbol: String = "magnifyingglass"
    /// Icon tile gradient.
    var colors: String = "#8fb8ff,#3a6fd8"
    /// Set for file tags (`downloads`, `pdf`, a folder path): search files, not a website.
    var files: FileScope? = nil
    /// Set for bookmark tags (`bookmark`, or a bookmark folder's name): search bookmarks.
    var bookmarks: BookmarkScope? = nil
    /// `history` tag: search the whole browser history.
    var history = false
    /// Came from the browser (a saved search engine or a bookmark folder), not built in.
    var fromBrowser = false
    /// Switches to one of Lumio's own tabs instead of locking a chip (`apps`, `content`,
    /// `clipboard`…): the tab's SpotlightKind raw value.
    var mode: String? = nil
    /// `settings` tag: System Settings panes only.
    var settingsOnly = false
    /// Opened for empty text instead of the template's own site (site tags search via Google).
    var home: String? = nil
    /// `windows` tag: the open windows of every app.
    var windows = false

    var isFileTag: Bool { files != nil }

    /// The site whose icon stands for this tag (web tags only): "youtube.com".
    var faviconHost: String? {
        guard files == nil, bookmarks == nil, !history, mode == nil, !settingsOnly, !windows else { return nil }
        if let home, let host = URLComponents(string: home)?.host { return host }
        if let domain { return domain.split(separator: "/").first.map(String.init) }
        return URLComponents(string: urlTemplate.replacingOccurrences(of: "{query}", with: ""))?.host
    }

    /// A file tag for one folder (typed path / Tab on a folder row).
    static func folder(_ path: String) -> SearchTag {
        let name = FileManager.default.displayName(atPath: path)
        return SearchTag(
            keyword: "folder:" + path.lowercased(), name: name, urlTemplate: "", domain: nil,
            symbol: "folder.fill", colors: "#6cb8f5,#2f7fe0", files: FileScope(folders: [path])
        )
    }

    /// One website (Tab on a link, an open tab or a history page): its open tabs and visited
    /// pages, and a web search limited to it.
    static func site(_ host: String) -> SearchTag {
        let clean = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return SearchTag(
            keyword: "site:" + clean, name: clean,
            urlTemplate: "https://www.google.com/search?q=site%3A\(clean)%20{query}", domain: clean,
            symbol: "globe", colors: "#8fb8ff,#3a6fd8", home: "https://" + host
        )
    }

    /// Two file tags stacked (`downloads` ⇥ `pdf` ⇥): both filters, both names.
    func stacked(with other: SearchTag) -> SearchTag? {
        // `bookmark` ⇥ `work` ⇥: bookmarks in the Work folder.
        if let mine = bookmarks, let theirs = other.bookmarks {
            return SearchTag(
                keyword: keyword + "+" + other.keyword, name: name + " · " + other.name,
                urlTemplate: "", domain: nil, symbol: other.symbol, colors: other.colors,
                bookmarks: BookmarkScope(folder: theirs.folder ?? mine.folder)
            )
        }
        guard let mine = files, let theirs = other.files else { return nil }
        return SearchTag(
            keyword: keyword + "+" + other.keyword, name: name + " · " + other.name,
            urlTemplate: "", domain: nil, symbol: other.symbol, colors: other.colors,
            files: mine.merged(with: theirs)
        )
    }

    /// The URL to open for `text`. Empty text opens the site's home page.
    func url(for text: String) -> URL? {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, urlTemplate.contains("{query}") else {
            return homeURL
        }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#/"))
        let encoded = term.addingPercentEncoding(withAllowedCharacters: allowed) ?? term
        return URL(string: urlTemplate.replacingOccurrences(of: "{query}", with: encoded))
    }

    /// Scheme + host of the template (`https://www.youtube.com`).
    var homeURL: URL? {
        if let home { return URL(string: home) }
        guard let parts = URLComponents(string: urlTemplate.replacingOccurrences(of: "{query}", with: "")),
              let scheme = parts.scheme, let host = parts.host
        else { return nil }
        return URL(string: "\(scheme)://\(host)")
    }

    /// Whether an open tab or history page belongs to this tag's site.
    func matches(url: String) -> Bool {
        guard let domain, let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        let path = URLComponents(string: url)?.path.lowercased() ?? ""
        // A domain may carry a path ("google.com/maps") to narrow it down.
        let parts = domain.lowercased().split(separator: "/", maxSplits: 1).map(String.init)
        let wantedHost = parts[0]
        guard host == wantedHost || host.hasSuffix("." + wantedHost) else { return false }
        if parts.count == 2 { return path.hasPrefix("/" + parts[1]) }
        return true
    }
}

/// Main-actor: the config path comes from the main-actor ConfigPathResolver.
enum SearchTags {
    nonisolated static let configPrefix = "search_tag_"

    /// Ready to use, no setup. Keywords are short on purpose: you type them often.
    nonisolated static let builtIns: [SearchTag] = [
        SearchTag(keyword: "g", name: "Google", urlTemplate: "https://www.google.com/search?q={query}",
                  domain: "google.com/search", symbol: "magnifyingglass", colors: "#8fb8ff,#3a6fd8"),
        SearchTag(keyword: "yt", name: "YouTube", urlTemplate: "https://www.youtube.com/results?search_query={query}",
                  domain: "youtube.com", symbol: "play.rectangle.fill", colors: "#ff7a7a,#d62929"),
        SearchTag(keyword: "drive", name: "Google Drive", urlTemplate: "https://drive.google.com/drive/search?q={query}",
                  domain: "drive.google.com", symbol: "externaldrive.fill", colors: "#ffd166,#1fa34a"),
        SearchTag(keyword: "docs", name: "Google Docs", urlTemplate: "https://docs.google.com/document/u/0/?q={query}",
                  domain: "docs.google.com", symbol: "doc.text.fill", colors: "#8fb8ff,#2b62d6"),
        SearchTag(keyword: "gmail", name: "Gmail", urlTemplate: "https://mail.google.com/mail/u/0/#search/{query}",
                  domain: "mail.google.com", symbol: "envelope.fill", colors: "#ff8a80,#d6453a"),
        SearchTag(keyword: "maps", name: "Google Maps", urlTemplate: "https://www.google.com/maps/search/{query}",
                  domain: "google.com/maps", symbol: "map.fill", colors: "#6ee07a,#1f9d4d"),
        SearchTag(keyword: "gh", name: "GitHub", urlTemplate: "https://github.com/search?q={query}",
                  domain: "github.com", symbol: "chevron.left.forwardslash.chevron.right", colors: "#a7aeb8,#30363d"),
        SearchTag(keyword: "r", name: "Reddit", urlTemplate: "https://www.reddit.com/search/?q={query}",
                  domain: "reddit.com", symbol: "bubble.left.and.bubble.right.fill", colors: "#ffa37a,#ff4500"),
        SearchTag(keyword: "x", name: "X", urlTemplate: "https://x.com/search?q={query}",
                  domain: "x.com", symbol: "at", colors: "#a7aeb8,#1d1d1f"),
        SearchTag(keyword: "w", name: "Wikipedia", urlTemplate: "https://en.wikipedia.org/w/index.php?search={query}",
                  domain: "wikipedia.org", symbol: "book.closed.fill", colors: "#c9ced6,#6b7280"),
        SearchTag(keyword: "amz", name: "Amazon", urlTemplate: "https://www.amazon.com/s?k={query}",
                  domain: "amazon.com", symbol: "cart.fill", colors: "#ffd166,#f08c00"),
        SearchTag(keyword: "gpt", name: "ChatGPT", urlTemplate: "https://chatgpt.com/?q={query}",
                  domain: "chatgpt.com", symbol: "sparkles", colors: "#7fe0c3,#10a37f"),
        SearchTag(keyword: "claude", name: "Claude", urlTemplate: "https://claude.ai/new?q={query}",
                  domain: "claude.ai", symbol: "sparkle", colors: "#f4b183,#d97757"),
        SearchTag(keyword: "gimg", name: "Google Images", urlTemplate: "https://www.google.com/search?tbm=isch&q={query}",
                  domain: nil, symbol: "photo.fill", colors: "#8fb8ff,#3a6fd8"),
        SearchTag(keyword: "tr", name: "Google Translate", urlTemplate: "https://translate.google.com/?text={query}",
                  domain: "translate.google.com", symbol: "character.bubble.fill", colors: "#8fb8ff,#3a6fd8"),
        SearchTag(keyword: "spotify", name: "Spotify", urlTemplate: "https://open.spotify.com/search/{query}",
                  domain: "open.spotify.com", symbol: "music.note", colors: "#7fe09a,#1db954"),
        SearchTag(keyword: "figma", name: "Figma", urlTemplate: "https://www.figma.com/files/search?q={query}",
                  domain: "figma.com", symbol: "pencil.and.outline", colors: "#c3a6ff,#a259ff"),
        SearchTag(keyword: "notion", name: "Notion", urlTemplate: "https://www.notion.so/search?q={query}",
                  domain: "notion.so", symbol: "note.text", colors: "#c9ced6,#37352f"),
    ] + fileTags + browserTags + fluentTags

    /// Fluent Search's own tag names, mapped to what Lumio has: `files`, `apps`, `settings`,
    /// `content`, `browser`… so muscle memory from Windows carries over.
    nonisolated static let fluentTags: [SearchTag] = {
        func mode(_ keyword: String, _ name: String, _ tab: String, _ symbol: String) -> SearchTag {
            SearchTag(keyword: keyword, name: name, urlTemplate: "", domain: nil, symbol: symbol,
                      colors: "#a7aeb8,#5e6670", mode: tab)
        }
        return [
            SearchTag(keyword: "files", name: "Files", urlTemplate: "", domain: nil, symbol: "doc.fill",
                      colors: "#a7aeb8,#5e6670", files: FileScope()),
            SearchTag(keyword: "file", name: "Files only", urlTemplate: "", domain: nil, symbol: "doc.fill",
                      colors: "#a7aeb8,#5e6670", files: FileScope(filesOnly: true)),
            SearchTag(keyword: "directory", name: "Folders", urlTemplate: "", domain: nil, symbol: "folder.fill",
                      colors: "#6cb8f5,#2f7fe0", files: FileScope(foldersOnly: true)),
            SearchTag(keyword: "browser", name: "Browser", urlTemplate: "", domain: nil, symbol: "globe",
                      colors: "#8fb8ff,#3a6fd8", bookmarks: BookmarkScope(), history: true),
            SearchTag(keyword: "settings", name: "Settings", urlTemplate: "", domain: nil, symbol: "gearshape.fill",
                      colors: "#9aa2ad,#5c636e", settingsOnly: true),
            SearchTag(keyword: "windows", name: "Open windows", urlTemplate: "", domain: nil, symbol: "macwindow.on.rectangle",
                      colors: "#9aa8ff,#4a4fd6", windows: true),
            SearchTag(keyword: "window", name: "Open windows", urlTemplate: "", domain: nil, symbol: "macwindow.on.rectangle",
                      colors: "#9aa8ff,#4a4fd6", windows: true),
            mode("apps", "Applications", "app", "square.grid.2x2.fill"),
            mode("app", "Applications", "app", "square.grid.2x2.fill"),
            // Fluent's `content` tag: words inside documents (Spotlight's text index). `ocr` is
            // Lumio's own tab for text inside images and scanned PDFs.
            SearchTag(keyword: "content", name: "File contents", urlTemplate: "", domain: nil,
                      symbol: "text.magnifyingglass", colors: "#a7aeb8,#5e6670",
                      files: FileScope(contentSearch: true)),
            mode("ocr", "Text in images & PDFs", "content", "text.viewfinder"),
            mode("clipboard", "Clipboard", "clip", "doc.on.clipboard"),
            mode("clip", "Clipboard", "clip", "doc.on.clipboard"),
            mode("process", "Processes", "process", "cpu"),
            mode("dictionary", "Dictionary", "lookup", "character.book.closed"),
            mode("define", "Dictionary", "lookup", "character.book.closed"),
            mode("translate", "Translate", "translation", "translate"),
            SearchTag(keyword: "bing", name: "Bing", urlTemplate: "https://www.bing.com/search?q={query}",
                      domain: "bing.com", symbol: "magnifyingglass", colors: "#7fd3e0,#0f7d8c"),
            SearchTag(keyword: "ddg", name: "DuckDuckGo", urlTemplate: "https://duckduckgo.com/?q={query}",
                      domain: "duckduckgo.com", symbol: "magnifyingglass", colors: "#ffb36e,#de5833"),
        ]
    }()

    /// Your browser's own data, Fluent-style: bookmarks and history as tags.
    nonisolated static let browserTags: [SearchTag] = [
        SearchTag(keyword: "bookmark", name: "Bookmarks", urlTemplate: "", domain: nil, symbol: "bookmark.fill",
                  colors: "#ffb36e,#f06a2e", bookmarks: BookmarkScope()),
        SearchTag(keyword: "bm", name: "Bookmarks", urlTemplate: "", domain: nil, symbol: "bookmark.fill",
                  colors: "#ffb36e,#f06a2e", bookmarks: BookmarkScope()),
        SearchTag(keyword: "history", name: "History", urlTemplate: "", domain: nil,
                  symbol: "clock.arrow.circlepath", colors: "#a7aeb8,#5e6670", history: true),
    ]

    /// File tags: folders, kinds of file and common extensions. Like Fluent Search's
    /// special-folder, group and extension tags.
    nonisolated static let fileTags: [SearchTag] = {
        let home = NSHomeDirectory()
        func folder(_ keyword: String, _ name: String, _ relative: String, _ symbol: String) -> SearchTag {
            SearchTag(keyword: keyword, name: name, urlTemplate: "", domain: nil, symbol: symbol,
                      colors: "#6cb8f5,#2f7fe0", files: FileScope(folders: [home + "/" + relative]))
        }
        func group(_ keyword: String, _ name: String, _ scope: FileScope, _ symbol: String, _ colors: String) -> SearchTag {
            SearchTag(keyword: keyword, name: name, urlTemplate: "", domain: nil, symbol: symbol,
                      colors: colors, files: scope)
        }
        var tags = [
            folder("desktop", "Desktop", "Desktop", "menubar.dock.rectangle"),
            folder("documents", "Documents", "Documents", "doc.on.doc.fill"),
            folder("downloads", "Downloads", "Downloads", "arrow.down.circle.fill"),
            folder("pictures", "Pictures", "Pictures", "photo.on.rectangle"),
            folder("music", "Music", "Music", "music.note"),
            folder("movies", "Movies", "Movies", "film"),
            folder("videos", "Movies", "Movies", "film"),
            folder("icloud", "iCloud Drive", "Library/Mobile Documents/com~apple~CloudDocs", "icloud.fill"),
            SearchTag(keyword: "home", name: "Home", urlTemplate: "", domain: nil, symbol: "house.fill",
                      colors: "#6cb8f5,#2f7fe0", files: FileScope(folders: [home])),
            group("recent", "Recent files", FileScope(recentOnly: true), "clock.fill", "#a7aeb8,#5e6670"),
            group("folder", "Folders", FileScope(foldersOnly: true), "folder.fill", "#6cb8f5,#2f7fe0"),
            group("image", "Images", FileScope(contentTypes: ["public.image"]), "photo.fill", "#7fe0c3,#1f9d8d"),
            group("img", "Images", FileScope(contentTypes: ["public.image"]), "photo.fill", "#7fe0c3,#1f9d8d"),
            group("video", "Videos", FileScope(contentTypes: ["public.movie"]), "film.fill", "#ff9f80,#e0503a"),
            group("audio", "Audio", FileScope(contentTypes: ["public.audio"]), "waveform", "#c3a6ff,#7a52d6"),
            group("document", "Documents", FileScope(extensions: [
                "pdf", "doc", "docx", "pages", "txt", "rtf", "md", "odt", "xls", "xlsx", "numbers",
                "csv", "ppt", "pptx", "key",
            ]), "doc.text.fill", "#8fb8ff,#2b62d6"),
            group("archive", "Archives", FileScope(extensions: ["zip", "rar", "7z", "tar", "gz", "dmg"]),
                  "archivebox.fill", "#d7b98a,#a07a3c"),
        ]
        for ext in ["pdf", "psd", "ai", "png", "jpg", "jpeg", "heic", "svg", "gif", "webp", "mp4", "mov",
                    "mp3", "wav", "docx", "xlsx", "pptx", "txt", "md", "zip", "dmg", "fig", "sketch", "prproj", "aep"] {
            tags.append(extensionTag(ext))
        }
        return tags
    }()

    /// `pdf` / `.pdf` → files ending in .pdf.
    nonisolated static func extensionTag(_ ext: String) -> SearchTag {
        let clean = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return SearchTag(
            keyword: clean, name: "." + clean, urlTemplate: "", domain: nil, symbol: "doc.fill",
            colors: "#a7aeb8,#5e6670", files: FileScope(extensions: [clean])
        )
    }

    /// Built-ins merged with the `search_tag_*` lines of the config (re-read on config reload).
    private static var cached: [SearchTag]?

    static var all: [SearchTag] {
        if let cached { return cached }
        // A built-in or your own config line wins over a browser-made tag with the same keyword.
        let builtInKeys = Set(builtIns.map(\.keyword))
        let fromBrowser = imported().filter { !builtInKeys.contains($0.keyword) }
        let loaded = merge(builtIns + fromBrowser, configLines: configLines(readConfig()))
        cached = loaded
        return loaded
    }

    /// Search engines saved in the browser (Chrome ▸ Settings ▸ Search engine ▸ Manage search
    /// engines and site search) and bookmark folders, as tags.
    private static func imported() -> [SearchTag] {
        // From memory only: the browsers' files are read off the main thread (see `warm()` on open).
        var tags = BrowserKeywords.cached.map { saved in
            SearchTag(
                keyword: saved.keyword, name: saved.name, urlTemplate: saved.template,
                domain: URLComponents(string: saved.template.replacingOccurrences(of: "{query}", with: ""))?.host,
                symbol: "magnifyingglass", colors: "#8fb8ff,#3a6fd8", fromBrowser: true
            )
        }
        for folder in BrowserBookmarks.folderNames(cachedOnly: true) {
            let keyword = folder.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !keyword.isEmpty else { continue }
            tags.append(SearchTag(
                keyword: keyword, name: folder, urlTemplate: "", domain: nil, symbol: "folder.fill",
                colors: "#ffb36e,#f06a2e", bookmarks: BookmarkScope(folder: folder), fromBrowser: true
            ))
        }
        // Plugged-in drives: `t7` ⇥ searches that drive, `drives` ⇥ all of them.
        let drives = ExternalDrives.mounted()
        for drive in drives {
            let keyword = drive.name.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !keyword.isEmpty else { continue }
            tags.append(SearchTag(
                keyword: keyword, name: drive.name, urlTemplate: "", domain: nil, symbol: "externaldrive.fill",
                colors: "#ffd166,#f08c00", files: FileScope(folders: [drive.path]), fromBrowser: true
            ))
        }
        if !drives.isEmpty {
            tags.append(SearchTag(
                keyword: "drives", name: "External Drives", urlTemplate: "", domain: nil,
                symbol: "externaldrive.fill", colors: "#ffd166,#f08c00",
                files: FileScope(folders: drives.map(\.path)), fromBrowser: true
            ))
        }
        // Remove later duplicates of a keyword (two profiles, a folder named like an engine).
        var seen = Set<String>()
        return tags.filter { seen.insert($0.keyword).inserted }
    }

    /// Drop the cache; the next lookup reads the config again.
    static func reload() {
        cached = nil
    }

    /// The tag whose keyword is exactly `text` (case-insensitive), e.g. "yt".
    static func tag(forKeyword text: String) -> SearchTag? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        if let tag = all.first(where: { $0.keyword == key }) { return tag }
        // The full name works as well as the short keyword, like in Fluent Search:
        // `youtube`, `google`, `googledrive`, `github`, `wikipedia`.
        if key.count >= 3, let tag = all.first(where: { compactName($0.name) == key }) { return tag }
        // `.xyz` + Tab: any extension, even one with no built-in tag.
        if key.hasPrefix("."), key.count >= 2, key.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber }) {
            return extensionTag(key)
        }
        return nil
    }

    /// "Google Drive" → "googledrive".
    nonisolated private static func compactName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A tag keyword at the START or the END of the text, and the rest of the text:
    /// `yt cats` and `cats yt` both give (YouTube, "cats"). The first word wins when both are tags.
    static func split(_ text: String) -> (tag: SearchTag, rest: String)? {
        let words = text.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        if let tag = tag(forKeyword: first) {
            return (tag, words.dropFirst().joined(separator: " "))
        }
        if words.count > 1, let last = words.last, let tag = tag(forKeyword: last) {
            return (tag, words.dropLast().joined(separator: " "))
        }
        return nil
    }

    /// Tags the typed text could be heading for: keyword or name starts with it. Used for the
    /// "press Tab" hint row. Exact keyword first; with several words, a keyword at either end.
    static func suggestions(for text: String, limit: Int = 2) -> [SearchTag] {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }
        if key.contains(" ") { return split(key).map { [$0.tag] } ?? [] }
        var out: [SearchTag] = []
        if let exact = tag(forKeyword: key) { out.append(exact) }
        guard key.count >= 2 else { return out }
        for tag in all where tag.keyword != key {
            if tag.name.lowercased().hasPrefix(key) || tag.name.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix(key) {
                out.append(tag)
            }
            if out.count >= limit { break }
        }
        return out
    }

    /// `search_tag_<keyword>=Name|url|domain` lines on top of the built-ins.
    nonisolated static func merge(_ base: [SearchTag], configLines: [(String, String)]) -> [SearchTag] {
        var tags = base
        for (key, value) in configLines where key.hasPrefix(configPrefix) {
            let keyword = String(key.dropFirst(configPrefix.count)).lowercased()
            guard !keyword.isEmpty, !keyword.contains(" ") else { continue }
            tags.removeAll { $0.keyword == keyword }
            let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // Empty value: turn the built-in off.
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
            let template = fields[1]
            let builtIn = base.first { $0.keyword == keyword }
            if template.lowercased().hasPrefix("folder:") {
                let paths = template.dropFirst(7).split(separator: ",").map {
                    ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
                }
                tags.append(SearchTag(keyword: keyword, name: fields[0], urlTemplate: "", domain: nil,
                                      symbol: "folder.fill", colors: "#6cb8f5,#2f7fe0",
                                      files: FileScope(folders: paths)))
                continue
            }
            if template.lowercased().hasPrefix("ext:") {
                let exts = template.dropFirst(4).split(separator: ",").map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
                }
                tags.append(SearchTag(keyword: keyword, name: fields[0], urlTemplate: "", domain: nil,
                                      symbol: "doc.fill", colors: "#a7aeb8,#5e6670",
                                      files: FileScope(extensions: exts)))
                continue
            }
            let domain = fields.count >= 3 && !fields[2].isEmpty
                ? fields[2]
                : URLComponents(string: template.replacingOccurrences(of: "{query}", with: ""))?.host
            tags.append(SearchTag(
                keyword: keyword, name: fields[0], urlTemplate: template, domain: domain,
                symbol: builtIn?.symbol ?? "magnifyingglass", colors: builtIn?.colors ?? "#8fb8ff,#3a6fd8"
            ))
        }
        return tags
    }

    /// `key=value` lines of the config, in file order. `#` comments and blank lines skipped.
    /// (Own tiny parser: ConfigFileLines is main-actor bound and this runs off the main thread.)
    nonisolated static func configLines(_ raw: String) -> [(String, String)] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("#"), let eq = text.firstIndex(of: "=") else { return nil }
            let key = text[..<eq].trimmingCharacters(in: .whitespaces)
            let value = text[text.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : (key, value)
        }
    }

    private static func readConfig() -> String {
        (try? String(contentsOfFile: ConfigPathResolver.resolvedPath(), encoding: .utf8)) ?? ""
    }
}


/// What a file tag narrows the search to. Empty fields don't narrow.
nonisolated struct FileScope: Equatable, Sendable {
    /// Search only inside these folders (absolute paths). Empty = your home folder.
    var folders: [String] = []
    /// File extensions, lowercased, no dot.
    var extensions: [String] = []
    /// Kinds of file (UTIs such as `public.image`), matched with subtypes.
    var contentTypes: [String] = []
    var foldersOnly = false
    /// `file` tag: no folders.
    var filesOnly = false
    /// `content` tag: match the words INSIDE documents, not their names.
    var contentSearch = false
    /// Only files opened, added or changed lately.
    var recentOnly = false

    func merged(with other: FileScope) -> FileScope {
        FileScope(
            folders: other.folders.isEmpty ? folders : other.folders,
            extensions: Array(Set(extensions + other.extensions)).sorted(),
            contentTypes: Array(Set(contentTypes + other.contentTypes)).sorted(),
            foldersOnly: foldersOnly || other.foldersOnly,
            filesOnly: filesOnly || other.filesOnly,
            contentSearch: contentSearch || other.contentSearch,
            recentOnly: recentOnly || other.recentOnly
        )
    }
}


/// What a bookmark tag narrows to: one folder (any depth), or every bookmark.
nonisolated struct BookmarkScope: Equatable, Sendable {
    var folder: String? = nil
}
