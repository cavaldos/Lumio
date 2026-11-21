//
//  FaviconStore.swift
//  lumio-app
//
//  Real site icons for web rows, like the browser's address bar and Fluent Search: a YouTube
//  row shows YouTube's icon, a Figma bookmark Figma's.
//
//  Icons come from the browsers' own icon store first (the `Favicons` database of each
//  Chromium profile: local, read-only, nothing leaves the Mac). Only for the sites of search
//  tags (youtube.com, google.com… public, not personal) a missing icon is fetched once from
//  Google's icon service and kept on disk. A history page whose icon is unknown falls back to
//  its browser's app icon.
//

import AppKit
import Combine
import SQLite3

/// Main-actor store: rows ask for an icon while drawing; a miss starts a background load and
/// publishes when it lands, so the row redraws with the real icon.
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    private var images: [String: NSImage] = [:]
    /// Hosts whose icon is light (ChatGPT's white logo): they need a dark plate behind them.
    private var lightIcons: Set<String> = []
    private var missing: Set<String> = []
    private var loading: Set<String> = []
    /// Hosts allowed a network fetch: search-tag sites only.
    private var remoteHosts: Set<String>?

    /// The icon for `host` ("youtube.com"), nil while unknown or loading.
    func image(for host: String) -> NSImage? {
        let key = Self.normalize(host)
        if let image = images[key] { return image }
        guard !missing.contains(key), !loading.contains(key) else { return nil }
        loading.insert(key)
        let allowRemote = remoteAllowed(key)
        Task.detached(priority: .utility) {
            let data = await FaviconLoader.load(host: key, allowRemote: allowRemote)
            await MainActor.run {
                self.loading.remove(key)
                if let data, let image = NSImage(data: data) {
                    self.images[key] = image
                    if Self.isLight(image) { self.lightIcons.insert(key) }
                    self.publishSoon()
                } else {
                    self.missing.insert(key)
                }
            }
        }
        return nil
    }

    /// Whether the icon for `host` is mostly white / very light, so it needs a dark plate.
    func isLight(_ host: String) -> Bool { lightIcons.contains(Self.normalize(host)) }

    /// Average brightness of the icon's visible pixels (sampled at 16×16).
    nonisolated private static func isLight(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0.0
        var weight = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.2 else { continue }
            // Premultiplied: divide the colour back out before measuring it.
            let red = Double(pixels[offset]) / 255 / alpha
            let green = Double(pixels[offset + 1]) / 255 / alpha
            let blue = Double(pixels[offset + 2]) / 255 / alpha
            total += (0.2126 * red + 0.7152 * green + 0.0722 * blue) * alpha
            weight += alpha
        }
        return weight > 0 && total / weight > 0.86
    }

    private var publishScheduled = false

    /// Several icons usually land together: one redraw for the batch, not one each.
    private func publishSoon() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.publishScheduled = false
            self.objectWillChange.send()
        }
    }

    private func remoteAllowed(_ host: String) -> Bool {
        if remoteHosts == nil {
            remoteHosts = Set(SearchTags.all.compactMap(\.faviconHost).map(Self.normalize))
        }
        return remoteHosts?.contains(host) ?? false
    }

    nonisolated static func normalize(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    /// "https://www.youtube.com/watch?v=1" → "youtube.com".
    nonisolated static func host(of url: String) -> String? {
        guard url.hasPrefix("http"), let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
        return normalize(host)
    }
}

nonisolated enum FaviconLoader {
    private static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.cavaldos.Lumio/favicons", isDirectory: true)
    }

    static func load(host: String, allowRemote: Bool) async -> Data? {
        let file = cacheDir.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".png")
        if let data = try? Data(contentsOf: file), !data.isEmpty { return data }
        if let data = fromBrowsers(host: host) {
            save(data, to: file)
            return data
        }
        guard allowRemote, let data = await fromNetwork(host: host) else { return nil }
        save(data, to: file)
        return data
    }

    private static func save(_ data: Data, to file: URL) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The largest icon any Chromium profile has stored for a page of this site.
    static func fromBrowsers(host: String) -> Data? {
        for profile in BrowserHistory.profiles() {
            let db = profile.dir.appendingPathComponent("Favicons")
            guard FileManager.default.fileExists(atPath: db.path) else { continue }
            if let data = query(db, host: host) { return data }
        }
        return nil
    }

    private static func query(_ db: URL, host: String) -> Data? {
        var handle: OpaquePointer?
        let path = db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db.path
        guard sqlite3_open_v2("file:\(path)?immutable=1", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        let sql = """
        SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
        WHERE (m.page_url LIKE ?1 OR m.page_url LIKE ?2) AND length(b.image_data) > 0
        ORDER BY b.width DESC LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, "%://\(host)/%", -1, transient)
        sqlite3_bind_text(statement, 2, "%://www.\(host)/%", -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        return count > 0 ? Data(bytes: bytes, count: count) : nil
    }

    private static func fromNetwork(host: String) async -> Data? {
        var parts = URLComponents(string: "https://www.google.com/s2/favicons")!
        parts.queryItems = [URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: "64")]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("Lumio", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count > 100
        else { return nil }
        return data
    }
}
