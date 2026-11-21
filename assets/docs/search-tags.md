# Search tags, files, browser tabs and suggestions

Inspired by [Fluent Search](https://fluentsearch.net/) on Windows: search a site, find any file on the Mac, jump to an open tab or open a recent file without leaving the keyboard, with no setup.

## Files from anywhere on the Mac

Lumio's own index (Desktop, Documents, Downloads) answers instantly with fuzzy matching (`mcd` → *My Cool Document*). A moment later, matches from **everywhere else in your home folder and iCloud Drive** are added below them, from the Spotlight index macOS already keeps. Every typed word must appear in the name; the best name match and the most recently used come first. App data (`~/Library`), hidden folders and the inside of app bundles are left out.

Results are ordered the way Fluent Search does it: **how well the name matches comes first** (exact name, then starts with the text, then a word starts with it, then contains it, then loose fuzzy matches). Within the same quality, what you use most comes first. The top row never moves once shown, so ⏎ stays predictable.

**It learns.** Whatever you open for a search is remembered with the text you typed; typing something similar later offers it first, instantly. Stored in `~/Library/Application Support/lumio/learned.json` (delete it to forget). The Rust core's own usage ranking for indexed apps and files is unchanged.

**Drag results out.** Drag a file, folder or app row into another app (Photoshop, a chat, Finder); a link row drags as a URL.

**Quick actions in the preview.** Apps and links list their actions (Open / Switch, Open New Instance, Show in file manager, Hide, Quit, Force Quit, Copy Path); files and folders get a strip (Open, Show, Search in Folder, Open in Editor, Copy Path). ⌘K still opens the full actions mode.

**Real site icons.** Web rows show the site's own icon, read from the browsers' local icon store; a page with no known icon shows its browser's app icon. Only search-tag sites (youtube.com, google.com…) fetch a missing icon once from Google's icon service.

**Picture thumbnails.** Images, videos and PSDs show what they look like in the list; PDFs and office documents keep their type icon (Quick Look, the thumbnailer Finder uses) instead of a generic file icon.

**External drives.** Plugged-in SSDs, USB sticks and SD cards are searched along with the home folder, with nothing to set up (each drive's own Spotlight index answers, so there is no file limit). Every drive is also a tag: `t7` ⇥ searches the drive named T7, `drives` ⇥ all of them. Settings ▸ General ▸ **Search external drives**, or `search_external_drives=false`.

**How much the instant index holds.** Lumio's own index (fuzzy, instant) is set by `file_scan_depth` (1–12) and `file_scan_limit` (500–50000) in the config; the defaults (4 deep, 8000 files) cut off large folders. For "find anything", use `file_scan_depth=12` and `file_scan_limit=50000`: code folders such as `node_modules` are skipped, so real files usually fit.

## Conversions

```text
5 km to miles      72 f in c       1.5 gb in mb      90 min to hours     2 cups to ml
100 usd to gbp     $250 in eur     20€ to gbp        100 usd   (→ your own currency)
```

⏎ copies the result. Units are Foundation's (length, weight, temperature, volume, speed, area, data, time). Currency uses the European Central Bank's public daily rates (about 30 major currencies), fetched at most twice a day and kept on disk; the request carries nothing about you or what you typed.

## Sorting, windows, system commands and more (Fluent Search parity, batch 2)

- **Sort the list.** The ↑↓ button in the footer, or ⌥S to step through: Default, Name, Date modified, File size, Type. Back to Default each time the launcher opens.
- **Open windows.** Windows of any app appear as results (⏎ switches to the window, minimized ones too), and `windows` ⇥ lists them all. Needs System Settings ▸ Privacy & Security ▸ **Accessibility** turned on for Lumio; without it there are no window rows and the `windows` tag says so.
- **System commands.** Type `lock`, `sleep`, `restart`, `shut down`, `log out`, `screen saver` or `empty trash`. Restart, Shut Down and Log Out show macOS's own confirmation dialog. Lock and Sleep act at once.
- **Run in Terminal.** `> npm run dev` then ⏎ runs the command in a new Terminal window, in your home folder. Nothing runs while you type.
- **Tab on an app** narrows to the files that app is the default for (Photoshop ⇥ → your PSDs, newest first). Browsers still go to bookmarks and history.
- **Uninstall…** in an app's actions moves it to the Trash (apps in an Applications folder, not running, second click confirms). Its support files are left alone.
- **Tag browser.** ⌥T lists every search tag; type to filter, ⏎ or ⇥ to use one.
- **Tag shortcuts.** Settings ▸ Shortcuts ▸ "Open straight into a search tag": a global key for files, Downloads, PSDs, bookmarks & history, open windows, or the tag browser.
- **⇧⏎** opens the separate preview window (Quick Look), like Fluent's Shift+Return. ⌘Y still works.
- **Index status.** Settings ▸ Indexing shows how many files, folders and apps are indexed, when, whether the macOS Spotlight index is on, and a **Rebuild** button.
- **Rank these file types last** and **Extra web search rows** in Settings ▸ Search (`low_priority_extensions=…`, `web_search_rows=yt,bing`).

## Home, pins and the detail card (Fluent Search parity)

- **Home.** The empty field lists your **pinned** results first, then the apps and files you use most. ↑↓ select, ⏎ opens.
- **Pin** anything with ⌘⇧P or "Pin to Home" in its actions (apps, files, folders, links). Stored in `~/Library/Application Support/lumio/pins.json`.
- **Detail card.** The right pane shows the result's icon (the picture itself for images and PSDs), Location, Modified, Size, **tag chips** (file, `.psd`, the parent folder, the app that opens it: click one to narrow the search to it) and **every action with its shortcut**. ⌥P or the eye button switches to the preview; the choice is remembered separately for files and folders (folders start on their newest-files list).
- **File actions:** Open ⏎, Show in file manager ⌘F, Search in Parent Folder ⌘R, Open in Terminal ⌘T, Open With…, Open in Editor ⌘E, Copy Path ⌘⇧C, Copy File, Rename…, Pin ⌘⇧P, Move to Trash ⌘D, Delete Permanently.
- **Tab on a selected file** narrows to its type ("press TAB to search for psd files"), as in Fluent; ⌘R searches its folder.
- **`content` ⇥** finds documents by the words inside them (Spotlight's text index). `ocr` ⇥ is the tab for text inside images and scanned PDFs.
- Typed words are bold in result titles; history rows show their address.
- Settings ▸ Search ▸ **Learned results ▸ Reset** forgets what Lumio learned from your picks.

## File tags

Like the web tags below, but for files. Type the keyword, press **Tab**, then type (or don't: an empty field lists the newest files first).

```text
downloads ⇥                → newest files in Downloads
downloads ⇥ invoice        → files in Downloads named like "invoice"
pdf ⇥ contract             → PDFs anywhere named like "contract"
downloads ⇥ pdf ⇥          → tags stack: PDFs in Downloads
image ⇥                    → your most recent images
~/Clients/Acme ⇥           → search inside any folder you type
(select a folder row) ⇥    → search inside that folder
.blend ⇥                   → any extension
```

| Kind | Keywords |
| --- | --- |
| Folders | `desktop` `documents` `downloads` `pictures` `music` `movies` / `videos` `icloud` `home` |
| Kinds | `image` / `img` `video` `audio` `document` `archive` `folder` `recent` |
| Browser | `browser` (bookmarks + history) `bookmark` / `bm` `history`, every bookmark folder, every saved search engine |
| Fluent Search names | `files` (files and folders) `file` (no folders) `folder` / `directory` `apps` `settings` `content` (text in images & PDFs) `clipboard` `process` `dictionary` `translate` `bing` `ddg` |
| Extensions | `pdf` `psd` `ai` `png` `jpg` `jpeg` `heic` `svg` `gif` `webp` `mp4` `mov` `mp3` `wav` `docx` `xlsx` `pptx` `txt` `md` `zip` `dmg` `fig` `sketch` `prproj` `aep`, or any `.ext` |

Your own:

```ini
search_tag_work=Work|folder:~/Clients/Work
search_tag_raw=RAW photos|ext:cr2,nef,arw,dng
```

## File manager

Folders open, and ⌘F / "Show in …" reveals files, in the file manager of your choice:

```ini
file_manager=auto            # default: the system file viewer if one is set, else Finder
file_manager=Path Finder     # a third-party file manager: an app name, a bundle id or a path
file_manager=finder
```

The same choice is in **Settings ▸ General ▸ Open folders in** (Automatic / Finder / the file managers found on your Mac). Settings ▸ General also has **Suggestions when empty**, **Web suggestions** and **Search external drives**.

`auto` picks up any file manager that registers itself as the macOS file viewer (the global `NSFileViewer` default), so it usually needs no setting at all.

## Search tags

Type a keyword and press **Tab**. The keyword becomes a chip, and what you type next is searched on that site.

```text
yt ⇥ lofi beats ⏎      → YouTube search for "lofi beats"
drive ⇥                → your open Drive tabs + recently visited Drive docs
gh ⇥ lumio ⏎           → GitHub search
```

- **Before or after the text**: `yt cats` ⇥ and `cats yt` ⇥ do the same thing. Forgot the tag? Add it at the end and press Tab. (Fluent Search needs the tag first; this is a Lumio extra.)
- The **full name works too**, as in Fluent Search: `youtube` ⇥, `google` ⇥, `googledrive` ⇥. While you type a partial name (`youtu…`), a **"Press Tab to search YouTube"** row appears and Tab takes it.
- **The end of the bar says what Tab will do**: *press TAB to search in Downloads*. With no keyword typed, Tab narrows to **what the selected result belongs to**: a folder → inside it, a file → its parent folder, a link / open tab / history page → that website, a browser app → your bookmarks and history. When nothing applies, Tab cycles the filter pills as before (Shift+Tab always does).
- Each tag is **its own chip**; **⌫** on the empty field removes the last one. **Esc** closes Lumio.
- With a tag active, the list shows: the search itself, **live search suggestions** (YouTube's own inside `yt`), open browser tabs on that site, then pages of the site you visited recently (newest first). ⏎ on a suggestion searches it.

Built-in keywords:

Web tags:

| Keyword | Site | Keyword | Site |
| --- | --- | --- | --- |
| `g` | Google | `w` | Wikipedia |
| `yt` | YouTube | `amz` | Amazon |
| `drive` | Google Drive | `gpt` | ChatGPT |
| `docs` | Google Docs | `claude` | Claude |
| `gmail` | Gmail | `gimg` | Google Images |
| `maps` | Google Maps | `tr` | Google Translate |
| `gh` | GitHub | `spotify` | Spotify |
| `r` | Reddit | `figma` | Figma |
| `x` | X | `notion` | Notion |

### Your own tags

In `~/.lumio/config` (then `Cmd+Shift+;` to reload):

```ini
# search_tag_<keyword>=Name|search URL with {query}|domain (optional)
search_tag_jira=Jira|https://acme.atlassian.net/issues/?jql=text~"{query}"
search_tag_npm=npm|https://www.npmjs.com/search?q={query}|npmjs.com
# Same keyword as a built-in replaces it; an empty value turns it off.
search_tag_x=
```

The domain decides which open tabs and history pages belong to the tag. It defaults to the URL's host and may carry a path (`google.com/maps`).

## Your browser, read like an extension

Lumio reads your browsers' own files (nothing to install in the browser, nothing leaves the Mac):

- **Bookmarks** show up in normal searches. `bookmark` ⇥ (or `bm` ⇥) lists them all, and **every bookmark folder becomes a tag**: a folder "Client Work" → `clientwork` ⇥.
- **History** shows up in normal searches too (pages you visit often and lately first; search-result and sign-in pages skipped). `history` ⇥ searches all of it.
- **Saved search engines** (Chrome / Edge / Brave / Arc / Vivaldi ▸ Settings ▸ Search engine ▸ Manage search engines and site search, including the ones the browser adds as you search a site) become tags automatically, e.g. `youtube.com` ⇥. Built-in and config tags win when a keyword clashes.

Safari bookmarks and history need **Full Disk Access** for Lumio; Chromium browsers don't. The first time, macOS may ask whether Lumio may access data from other apps.

### Search suggestions

```ini
web_suggestions=always   # default: in normal searches and inside web tags
web_suggestions=tags     # only inside web tags
web_suggestions=off
```

This is the one feature that sends what you type off the Mac: to Google's suggestion service (the one browsers use), from the third character on. On by default, as in Fluent Search and browsers' address bars; `tags` keeps normal searches local.

## Open browser tabs

Tabs open in **Safari, Chrome, Arc, Brave, Edge, Vivaldi, Chromium and Opera** show up in normal search results (after the best match) and under search tags. **⏎ switches to the tab** instead of opening a new one.

- Read over AppleScript, only from browsers that are already running; Lumio never launches a browser.
- macOS asks once per browser: *"Lumio wants to control Safari"*. If you click Don't Allow, that browser's tabs are skipped. Change it later in System Settings ▸ Privacy & Security ▸ Automation.
- The list is a snapshot taken when Lumio opens, so typing never waits on the browser.
- Firefox has no AppleScript access to its tabs.

## Recent history (for tags)

- **Chromium browsers** (Chrome, Arc, Brave, Edge, Vivaldi): read directly from the profile's `History` file, read-only, every profile.
- **Safari**: needs **Full Disk Access** for Lumio (System Settings ▸ Privacy & Security ▸ Full Disk Access). Without it Safari history is skipped; open Safari tabs still work.
- Nothing leaves your Mac.

## Suggestions on open

With an empty field Lumio lists the **apps and files you use most**, so ⏎ often opens what you want before you type. Ranked by frecency: every day you opened a file counts, recent days count more, so a file you open daily beats one you opened once an hour ago. **Files that just landed in Downloads** are suggested too. Comes from the Spotlight index's "opened on" dates, so there is no history to build up. Files inside `~/Library`, hidden folders and bundles are left out.

This replaces the four round buttons on the empty field (`Cmd+1` … `Cmd+4` still work). To get the old empty state back:

```ini
suggestions_on_open=false
```

## Code

| File | What |
| --- | --- |
| `Support/Browser/SearchTags.swift` | Tag model, built-ins, `search_tag_*` config |
| `Support/Browser/BrowserTabs.swift` | Tab snapshot + switching over AppleScript |
| `Support/Browser/BrowserHistory.swift` | Chromium + Safari history, read-only |
| `Support/Browser/BrowserBookmarks.swift` | Chromium + Safari bookmarks, folders as tags |
| `Support/Browser/BrowserKeywords.swift` | Browser-saved search engines as tags |
| `Support/Browser/WebSuggestions.swift` | Live search suggestions (`web_suggestions`) |
| `Support/Browser/FaviconStore.swift` | Site icons from the browsers' icon store |
| `Views/Spotlight/UsageLearning.swift` | Remembers what you open for which text |
| `Support/Launcher/RecentItems.swift` | Suggested apps / files (frecency) via Spotlight |
| `Support/Launcher/SpotlightFiles.swift` | Whole-Mac file search and file tags via Spotlight |
| `Support/Launcher/FileManagerApp.swift` | `file_manager` setting: open / reveal in any file manager |
| `Views/Spotlight/SpotlightBackend.swift` | Rows for tabs, tags, hints and suggestions |
| `Views/Spotlight/SpotlightLauncherView.swift` | Tag chip, Tab key, suggestions on the empty field |

## Building without Xcode

`scripts/build-without-xcode.sh` builds `Lumio.app` with only the Command Line Tools (`swiftc`, `cargo`): it compiles the Swift sources directly, links the Rust core and signs the bundle ad hoc. No Sparkle auto-update in that build.

### When the Accessibility permission goes stale

Window search and looking up the selected text need the Accessibility permission. Lumio tells three states apart:

- **Working**: macOS allows it and a real request goes through.
- **Off**: Lumio is not in the list, or its switch is off. Lumio stays quiet about this.
- **Stale**: the switch is on in System Settings, but macOS ignores it (the entry belongs to an older copy of Lumio). Flipping the switch does not help.

A stale permission gets a dialog once per launch with **Reset and Allow Again**, which removes only Lumio's entry from the Accessibility list so it can be added fresh. Settings ▸ General ▸ Permissions shows the current state with a button that opens the same dialog for any state, and ⏎ on the row the `windows` tag shows while it is unavailable does too. After a fix, a second dialog says whether it took.

Telling stale from off for certain needs Full Disk Access (that is where macOS keeps the list). Without it, Lumio goes by whether the permission worked before.
