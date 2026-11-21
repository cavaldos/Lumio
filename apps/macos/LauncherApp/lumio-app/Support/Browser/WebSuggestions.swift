//
//  WebSuggestions.swift
//  lumio-app
//
//  Search suggestions as you type, like the browser's address bar and Fluent Search: inside
//  `yt` ⇥ typing "lofi" lists "lofi hip hop radio", "lofi girl"…, and ⏎ on one searches it.
//
//  Privacy: this is the one feature that sends what you type off the Mac (to Google's public
//  suggestion endpoint, the one browsers use), from the third character on. On by default,
//  as in Fluent Search and every browser's address bar. ~/.lumio/config:
//
//    web_suggestions=always   under normal searches and inside web tags (default)
//    web_suggestions=tags     only inside a web search tag (text you are about to search
//                             on the web anyway); normal searches never leave the Mac
//    web_suggestions=off      never
//

import Foundation

nonisolated enum WebSuggestions {
    enum Mode: String, Sendable { case tags, always, off }

    static let configKey = "web_suggestions"

    @MainActor static var mode: Mode {
        let raw = (try? String(contentsOfFile: ConfigPathResolver.resolvedPath(), encoding: .utf8)) ?? ""
        let value = SearchTags.configLines(raw).last(where: { $0.0 == configKey })?.1.lowercased() ?? ""
        switch value {
        case "tags", "tag": return .tags
        case "off", "false", "no", "0": return .off
        default: return .always
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [String]] = [:]

    /// Up to `limit` suggestions for `text` (YouTube's own list inside the YouTube tag).
    /// Empty on any error or after `timeout`: suggestions are a bonus, never a wait.
    static func fetch(_ text: String, youtube: Bool, limit: Int = 5, timeout: TimeInterval = 1.2) async -> [String] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return [] }
        let key = (youtube ? "yt|" : "g|") + term.lowercased()
        if let hit = cached(key) { return Array(hit.prefix(limit)) }

        var parts = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        parts.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: term)]
        if youtube { parts.queryItems?.append(URLQueryItem(name: "ds", value: "yt")) }
        guard let url = parts.url else { return [] }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        request.setValue("Lumio", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        let suggestions = parse(data).filter { $0.lowercased() != term.lowercased() }
        store(key, suggestions)
        return Array(suggestions.prefix(limit))
    }

    /// For `Lumio --browser-check`: what the suggestion request actually returns from inside
    /// the app (status code or the error), bypassing the cache.
    static func diagnose(_ text: String) async -> String {
        var parts = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        parts.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: text)]
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("Lumio", forHTTPHeaderField: "User-Agent")
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return "HTTP \(code), \(data.count) bytes, \(parse(data).count) suggestions, \(ms) ms"
        } catch {
            return "FAILED: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)"
        }
    }

    private static func cached(_ key: String) -> [String]? {
        lock.withLock { cache[key] }
    }

    private static func store(_ key: String, _ value: [String]) {
        lock.withLock {
            if cache.count > 200 { cache.removeAll() }
            cache[key] = value
        }
    }

    /// `["query", ["suggestion 1", "suggestion 2", …], …]`
    static func parse(_ data: Data) -> [String] {
        // The endpoint answers in the user's locale encoding; fall back to Latin-1.
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              json.count >= 2, let list = json[1] as? [String]
        else { return [] }
        return list
    }
}
