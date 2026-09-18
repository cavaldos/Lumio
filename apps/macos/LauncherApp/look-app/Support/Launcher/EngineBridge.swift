import Foundation

/// The row a tool action acts on.
nonisolated struct ToolActionRow {
    let candidateID: String
    let title: String
    let path: String
    var ancestorsJSON: String = "[]"

    func withCStrings<T>(
        _ body: (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
            UnsafePointer<CChar>?) -> T
    ) -> T {
        candidateID.withCString { candidate in
            title.withCString { title in
                path.withCString { path in
                    ancestorsJSON.withCString { ancestors in
                        body(candidate, title, path, ancestors)
                    }
                }
            }
        }
    }
}

@_silgen_name("look_search_json")
nonisolated
private func look_search_json(_ query: UnsafePointer<CChar>?, _ limit: UInt32) -> UnsafeMutablePointer<CChar>?

@_silgen_name("look_search_json_compact")
nonisolated
private func look_search_json_compact(_ query: UnsafePointer<CChar>?, _ limit: UInt32) -> UnsafeMutablePointer<CChar>?


@_silgen_name("look_record_usage_json")
nonisolated
private func look_record_usage_json(_ candidateID: UnsafePointer<CChar>?, _ action: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("look_free_cstring")
nonisolated
private func look_free_cstring(_ ptr: UnsafeMutablePointer<CChar>?)

@_silgen_name("look_reload_config")
nonisolated
private func look_reload_config() -> Bool

@_silgen_name("look_request_index_refresh")
nonisolated
private func look_request_index_refresh() -> Bool

@_silgen_name("look_translate_json")
nonisolated
private func look_translate_json(_ text: UnsafePointer<CChar>?, _ targetLang: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("look_fuzzy_score")
nonisolated
private func look_fuzzy_score(_ query: UnsafePointer<CChar>?, _ title: UnsafePointer<CChar>?) -> Int64



































@_silgen_name("look_classify_url_json")
nonisolated
private func look_classify_url_json(_ query: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("look_record_url_hit")
nonisolated
private func look_record_url_hit(_ url: UnsafePointer<CChar>?) -> Bool

@_silgen_name("look_recent_urls_json")
nonisolated
private func look_recent_urls_json(_ query: UnsafePointer<CChar>?, _ limit: UInt32) -> UnsafeMutablePointer<CChar>?

@_silgen_name("look_clipboard_record")
nonisolated
private func look_clipboard_record(_ content: UnsafePointer<CChar>?, _ appBundleID: UnsafePointer<CChar>?) -> Int64

@_silgen_name("look_clipboard_record_image")
nonisolated
private func look_clipboard_record_image(_ label: UnsafePointer<CChar>?, _ imageHash: UnsafePointer<CChar>?, _ appBundleID: UnsafePointer<CChar>?) -> Int64

@_silgen_name("look_clipboard_images_dir")
nonisolated
private func look_clipboard_images_dir() -> UnsafeMutablePointer<CChar>?

@_silgen_name("look_clipboard_list_json")
nonisolated
private func look_clipboard_list_json(_ kind: UnsafePointer<CChar>?, _ query: UnsafePointer<CChar>?, _ limit: UInt32) -> UnsafeMutablePointer<CChar>?

@_silgen_name("look_clipboard_delete")
nonisolated
private func look_clipboard_delete(_ id: Int64) -> Bool

@_silgen_name("look_clipboard_clear")
nonisolated
private func look_clipboard_clear() -> UInt32








@_silgen_name("look_lunar_date_json")
nonisolated
private func look_lunar_date_json(_ year: Int64, _ month: Int64, _ day: Int64, _ tz: Double) -> UnsafeMutablePointer<CChar>?







@_silgen_name("look_tool_action_json")
nonisolated
private func look_tool_action_json(_ action: UnsafePointer<CChar>?, _ candidateID: UnsafePointer<CChar>?, _ rowTitle: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?, _ isDir: Bool, _ ancestorsJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("look_perform_tool_action_json")
nonisolated
private func look_perform_tool_action_json(_ action: UnsafePointer<CChar>?, _ candidateID: UnsafePointer<CChar>?, _ rowTitle: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?, _ isDir: Bool, _ ancestorsJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("look_netspeed_run_json")
nonisolated
private func look_netspeed_run_json() -> UnsafeMutablePointer<CChar>?

/// One measurement from the shared `core/netspeed` crate. The display strings
/// are formatted in core so every shell prints the same text.
nonisolated struct SpeedReading: Codable, Sendable, Equatable {
    let downloadBitsPerSecond: Double
    let uploadBitsPerSecond: Double
    let latencyMs: Double?
    let downloadDisplay: String
    let uploadDisplay: String
    let latencyDisplay: String
    let downloadVerdict: String
    let latencyVerdict: String
    let latencyLevel: String?
    let downloadSource: String?
    var publicIp: String?
    let provider: String?
    let location: String?
    let measuredAtUnix: Int

    var measuredAt: Date {
        Date(timeIntervalSince1970: TimeInterval(measuredAtUnix))
    }
}

/// Stands in when the bridge cannot make sense of the reply at all; every other
/// message the panel shows comes from core's `SpeedError`.
private nonisolated let speedTestUnknownFailure = "Speed test failed"

nonisolated struct SpeedTestEnvelope: Decodable {
    let ok: Bool
    let reading: SpeedReading?
    let error: String?
}

nonisolated enum SpeedTestOutcome: Sendable {
    case reading(SpeedReading)
    case failure(String)
}

/// A resolved lunar date from the shared `core/lunar` crate (East Asian
/// lunisolar calendar). `leap` marks the intercalary month of a 13-month year.
nonisolated struct LunarDate: Decodable {
    let day: Int
    let month: Int
    let year: Int
    let leap: Bool
}

final class EngineBridge: @unchecked Sendable {
    nonisolated static let shared = EngineBridge()

    nonisolated private init() {}

    nonisolated func search(query: String, limit: Int = 40) -> [LauncherResult] {
        let ptr = query.withCString { cstr in
            look_search_json_compact(cstr, UInt32(limit))
        }

        guard let ptr else {
            return fallbackResults()
        }

        defer {
            look_free_cstring(ptr)
        }

        let raw = String(cString: ptr)
        guard let data = raw.data(using: .utf8) else {
            return fallbackResults()
        }

        if let compactPayload = try? JSONDecoder().decode(CompactSearchPayload.self, from: data) {
            if compactPayload.error != nil {
                return fallbackResults()
            }
            return compactPayload.results.map { LauncherResult($0, defaultKind: .app) }
        }

        // Compatibility fallback for older JSON payload shape.
        guard let fullPayload = try? JSONDecoder().decode(SearchPayload.self, from: data),
            fullPayload.error == nil
        else {
            return fallbackResults()
        }

        return fullPayload.results.map { LauncherResult($0, defaultKind: .app) }
    }












    nonisolated func recordUsage(candidateID: String, action: String) -> BridgeError? {
        let ptr = candidateID.withCString { idCstr in
            action.withCString { actionCstr in
                look_record_usage_json(idCstr, actionCstr)
            }
        }

        guard let ptr else {
            return BridgeError(code: "ffi_null_response", message: "Usage tracking is temporarily unavailable")
        }

        defer {
            look_free_cstring(ptr)
        }

        let raw = String(cString: ptr)
        guard let data = raw.data(using: .utf8),
            let payload = try? JSONDecoder().decode(UsageRecordPayload.self, from: data)
        else {
            return BridgeError(code: "decode_failed", message: "Usage tracking response could not be decoded")
        }

        return payload.error
    }

    nonisolated func reloadConfig() -> Bool {
        look_reload_config()
    }

    @discardableResult
    nonisolated func requestIndexRefresh() -> Bool {
        look_request_index_refresh()
    }

    /// Lunar date from the shared core. `tzHours` is the viewer's UTC offset,
    /// which selects the calendar variant (7 = Vietnamese, 8 = Chinese).
    nonisolated func lunarDate(year: Int, month: Int, day: Int, tzHours: Double) -> LunarDate? {
        guard let ptr = look_lunar_date_json(Int64(year), Int64(month), Int64(day), tzHours) else {
            return nil
        }
        defer { look_free_cstring(ptr) }
        guard let data = String(cString: ptr).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LunarDate.self, from: data)
    }

    /// Runs the shared core speed test. Blocks for 15 seconds and up, so call it
    /// off the main thread. There is no cancel: core bounds each phase with its
    /// own timeout.
    nonisolated func speedTest() -> SpeedTestOutcome {
        guard let ptr = look_netspeed_run_json() else {
            return .failure(speedTestUnknownFailure)
        }
        defer { look_free_cstring(ptr) }

        guard let data = String(cString: ptr).data(using: .utf8) else {
            return .failure(speedTestUnknownFailure)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? decoder.decode(SpeedTestEnvelope.self, from: data) else {
            return .failure(speedTestUnknownFailure)
        }
        guard envelope.ok, let reading = envelope.reading else {
            return .failure(envelope.error ?? speedTestUnknownFailure)
        }
        return .reading(reading)
    }

    nonisolated func translate(text: String, targetLang: String = "en") -> TranslationResult? {
        let result = text.withCString { textCstr in
            targetLang.withCString { langCstr in
                look_translate_json(textCstr, langCstr)
            }
        }

        guard let result else {
            return nil
        }

        defer {
            look_free_cstring(result)
        }

        let raw = String(cString: result)
        guard let data = raw.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(TranslationResult.self, from: data)
    }

























    nonisolated func fuzzyScore(query: String, title: String) -> Int? {
        let score = query.withCString { queryCstr in
            title.withCString { titleCstr in
                look_fuzzy_score(queryCstr, titleCstr)
            }
        }
        return score == Int64.min ? nil : Int(score) // Int64.min = NO_MATCH sentinel
    }








    /// Classifies `query` as a URL, or nil to leave it as a search term.
    /// Network-free; shares the Rust core's tier rules and TLD list with linows.
    nonisolated func classifyURL(query: String) -> URLMatch? {
        let ptr = query.withCString { look_classify_url_json($0) }
        guard let ptr else { return nil }
        defer { look_free_cstring(ptr) }
        let raw = String(cString: ptr)
        guard raw != "null", let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(URLMatch.self, from: data)
    }

    /// Records that `url` was opened through the launcher, for later re-open
    /// suggestions. Fire-and-forget; opens the shared look.db (own connection).
    @discardableResult
    nonisolated func recordURLHit(url: String) -> Bool {
        url.withCString { look_record_url_hit($0) }
    }



    /// What `action` would do to a row, without doing it: the tool it would
    /// start, or why it cannot. For labels and availability.
    nonisolated func toolAction(
        _ action: String, row: ToolActionRow, isDirectory: Bool
    ) -> ToolAction? {
        let ptr = row.withCStrings { candidate, title, path, ancestors in
            action.withCString { action in
                look_tool_action_json(action, candidate, title, path, isDirectory, ancestors)
            }
        }
        return Self.decodeToolAction(ptr)
    }

    /// Runs `action` on a row. Shell actions are spawned detached inside core;
    /// an `application` result is handed back for `NSWorkspace` to launch.
    /// Spawns a process, so call it off the main thread.
    nonisolated func performToolAction(
        _ action: String, row: ToolActionRow, isDirectory: Bool
    ) -> ToolAction? {
        let ptr = row.withCStrings { candidate, title, path, ancestors in
            action.withCString { action in
                look_perform_tool_action_json(action, candidate, title, path, isDirectory, ancestors)
            }
        }
        return Self.decodeToolAction(ptr)
    }

    private nonisolated static func decodeToolAction(_ ptr: UnsafeMutablePointer<CChar>?) -> ToolAction? {
        guard let ptr else { return nil }
        defer { look_free_cstring(ptr) }
        guard let data = String(cString: ptr).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ToolAction.self, from: data)
    }





    /// Up to `limit` previously-opened URLs matching `query`, most-recent first.
    /// Opens the shared look.db - call off the main thread.
    nonisolated func recentURLs(query: String, limit: Int) -> [URLHistoryEntry] {
        let ptr = query.withCString { look_recent_urls_json($0, UInt32(limit)) }
        guard let ptr else { return [] }
        defer { look_free_cstring(ptr) }
        guard let data = String(cString: ptr).data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode([URLHistoryEntry].self, from: data)) ?? []
    }

    /// One remembered clip, as stored in the shared look.db.
    nonisolated struct ClipboardEntry: Decodable, Identifiable, Equatable {
        let id: Int64
        let content: String
        /// Identity of what was copied. For an image clip it is also the stem
        /// of the file holding the pixels.
        let contentHash: String
        let appBundleID: String?
        let copiedAtUnixS: Int64

        var copiedAt: Date { Date(timeIntervalSince1970: TimeInterval(copiedAtUnixS)) }
    }

    /// Remembers a clip and returns its row id, or nil when nothing was
    /// stored. The id is the handle a later delete needs: without it, deleting
    /// the clip would only drop the in-memory copy and it would return on the
    /// next launch.
    ///
    /// NEVER call this for a concealed or transient clip: the core cannot see
    /// pasteboard type markers, so this side is the only place a password
    /// manager's clip can be kept out of the database.
    /// Opens the shared look.db - call off the main thread.
    @discardableResult
    nonisolated func recordClipboard(content: String, appBundleID: String? = nil) -> Int64? {
        let id = content.withCString { contentC in
            if let appBundleID {
                return appBundleID.withCString { appC in
                    look_clipboard_record(contentC, appC)
                }
            }
            return look_clipboard_record(contentC, nil)
        }
        return id > 0 ? id : nil
    }

    /// Remembers a copied image and returns its row id. `imageHash` names the
    /// file this side already wrote into `clipboardImagesDirectory()`; the row
    /// is what keeps that file from being swept.
    ///
    /// Same concealed-clip rule as `recordClipboard`: only this side sees the
    /// pasteboard markers.
    @discardableResult
    nonisolated func recordClipboardImage(
        label: String, imageHash: String, appBundleID: String? = nil
    ) -> Int64? {
        let id = label.withCString { labelC in
            imageHash.withCString { hashC in
                if let appBundleID {
                    return appBundleID.withCString { appC in
                        look_clipboard_record_image(labelC, hashC, appC)
                    }
                }
                return look_clipboard_record_image(labelC, hashC, nil)
            }
        }
        return id > 0 ? id : nil
    }

    /// Where image clips keep their bytes. Core owns the location and sweeps
    /// anything in it that no row claims, so this side asks rather than
    /// assembling the path itself.
    nonisolated func clipboardImagesDirectory() -> URL? {
        guard let ptr = look_clipboard_images_dir() else { return nil }
        defer { look_free_cstring(ptr) }
        let path = String(cString: ptr)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// Up to `limit` remembered clips of `kind` matching `query` (newest
    /// first). An empty query returns the most recent. Opens look.db - call off
    /// the main thread.
    nonisolated func clipboardEntries(
        kind: String = AppConstants.Launcher.Clipboard.textKind,
        query: String = "",
        limit: Int
    ) -> [ClipboardEntry] {
        let ptr = kind.withCString { kindC in
            query.withCString { queryC in
                look_clipboard_list_json(kindC, queryC, UInt32(limit))
            }
        }
        guard let ptr else { return [] }
        defer { look_free_cstring(ptr) }
        guard let data = String(cString: ptr).data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ClipboardEntry].self, from: data)) ?? []
    }

    @discardableResult
    nonisolated func deleteClipboardEntry(id: Int64) -> Bool {
        look_clipboard_delete(id)
    }

    /// Forgets every clip, returning how many were removed.
    @discardableResult
    nonisolated func clearClipboardHistory() -> Int {
        Int(look_clipboard_clear())
    }









    nonisolated private func fallbackResults() -> [LauncherResult] {
        []
    }
}


nonisolated struct TranslationResult: Decodable {
    let original: String
    let translated: String
    let error: BridgeError?
}

/// Wire shape of `look_answers::UrlMatch`: the resolved openable URL and how
/// certain the classification is. `tier` decodes the lowercased Rust enum
/// (`structural` / `barehost`).
nonisolated struct URLMatch: Decodable {
    enum Tier: String, Decodable {
        case structural
        case bareHost = "barehost"
    }

    let url: String
    let tier: Tier
}

/// A user-declared block and the steps performing it will run, so the panel can
/// show exactly what Enter is about to do.
/// One preferred-tool action resolved against a row. `kind` says which of the
/// other fields are filled.
nonisolated struct ToolAction: Decodable {
    enum Kind: String, Decodable {
        /// Composed shell text. Only `look_tool_action_json` returns this;
        /// performing runs it in core and reports `performed` or `failed`.
        case shell
        /// The native side launches `tool` with `path`.
        case application
        /// Nothing declared, so the platform's own handler does it.
        case systemDefault = "system_default"
        /// Core spawned it.
        case performed
        case failed
        /// No tool declared, or one that cannot do this.
        case unavailable
    }

    let kind: Kind
    let tool: String?
    let command: String?
    let path: String?
    /// Shown as-is when `kind` is `unavailable` or `failed`.
    let reason: String?
    /// The config key that would fix an `unavailable` action.
    let key: String?
    /// A block declared this action for its own rows, so `tool` names the
    /// block: "Open in Projects" is not a label worth showing.
    let fromBlock: Bool
}

/// The row a block's placeholders expand against. One struct because the three
/// always travel together, mirroring `RowArgs` on the Tauri side - and because
/// they used to be three defaulted parameters, which let a call site drop the
/// row and render `shortcuts run ''` while Enter still ran the real command.
nonisolated struct RowRef {
    let id: String
    let title: String
    let path: String

    /// The selected row as the engine takes it. `id` is the candidate id: core
    /// strips the `src:<block>:` namespace, so a block asking for `{id}` gets
    /// the row's own id rather than the whole thing.
    init(_ result: LauncherResult) {
        id = result.id
        title = result.title
        path = result.path
    }
}






/// How performing a block went. `errors` is empty when every step was spawned;
/// a step's own exit code is its business, since nothing waits for it.
nonisolated struct PerformBlockOutcome: Decodable {
    let performed: Int
    let errors: [String]
    /// The target lists rows to pick from rather than steps to run. An explicit
    /// flag, because "nothing performed" is also what a failure looks like.
    let producesRows: Bool
    /// Nothing declared and the row has a path, so it opens like any file. The
    /// core decides this, not the row's kind.
    let opensPath: Bool
}

/// Wire shape of a `url_history` row (see url-history spec), decoded with
/// `.convertFromSnakeCase`. `title` is reserved and nil today.
nonisolated struct URLHistoryEntry: Decodable {
    let url: String
    let title: String?
    let hitCount: Int
    let lastUsedAtUnixS: Int
    /// Frecency rank from the Rust core (same `rank_score` as apps/files), used
    /// to place recent URLs among local results rather than a fixed threshold.
    let score: Int
}

private nonisolated struct SearchPayload: Decodable {
    let query: String
    let count: Int
    let results: [SearchItem]
    /// File recall only: which fallback produced the results (see
    /// EngineBridge.FileRecallOutcome).
    let relaxed: String?
    let error: BridgeError?
}

private nonisolated struct CompactSearchPayload: Decodable {
    let count: Int
    let results: [SearchItem]
    let error: BridgeError?
}

private nonisolated struct UsageRecordPayload: Decodable {
    let ok: Bool
    let error: BridgeError?
}

nonisolated struct BridgeError: Decodable {
    let code: String
    let message: String

    var userFacingMessage: String {
        BridgeErrorMapping.userFacingMessage(code: code, fallback: message)
    }
}

private nonisolated struct SearchItem: Decodable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String?
    let path: String
    let score: Int
    let icon: String?
}

extension LauncherResult {
    /// One decode of a search payload row. Spelled out per call site, every new
    /// field the core adds is a three-site edit, and the sites drift: `icon`
    /// reached search results and missed file recall entirely.
    fileprivate nonisolated init(_ item: SearchItem, defaultKind: LauncherResultKind) {
        self.init(
            id: item.id,
            kind: LauncherResultKind(rawValue: item.kind) ?? defaultKind,
            title: item.title,
            subtitle: item.subtitle,
            path: item.path,
            score: item.score,
            icon: item.icon
        )
    }
}
