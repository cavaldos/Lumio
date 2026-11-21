//
//  AppDocuments.swift
//  lumio-app
//
//  Tab on an app narrows the search to the files that app opens (Fluent Search's app tag):
//  Photoshop ⇥ lists your PSDs, newest first; type to narrow them.
//
//  The file types come from the app's own Info.plist. An app like Photoshop claims dozens
//  (every image format), so only the types it is the DEFAULT app for are kept. An app that
//  is the default for none of its types gets no tag.
//

import AppKit
import UniformTypeIdentifiers

enum AppDocuments {
    /// Per app path; `.some(nil)` = looked up, this app opens no documents.
    private static var cache: [String: SearchTag?] = [:]

    static func tag(forApp path: String) -> SearchTag? {
        if let known = cache[path] { return known }
        let tag = build(path)
        cache[path] = tag
        return tag
    }

    private static func build(_ path: String) -> SearchTag? {
        guard let info = Bundle(path: path)?.infoDictionary,
              let types = info["CFBundleDocumentTypes"] as? [[String: Any]]
        else { return nil }
        var extensions: [String] = []
        for type in types {
            extensions += type["CFBundleTypeExtensions"] as? [String] ?? []
            for identifier in type["LSItemContentTypes"] as? [String] ?? [] {
                extensions += UTType(identifier)?.tags[.filenameExtension] ?? []
            }
        }
        var seen = Set<String>()
        extensions = extensions
            .map { $0.lowercased() }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber } && seen.insert($0).inserted }
        guard !extensions.isEmpty else { return nil }

        let app = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let owned = extensions.filter { ext in
            guard let type = UTType(filenameExtension: ext),
                  let handler = NSWorkspace.shared.urlForApplication(toOpen: type)
            else { return false }
            return handler.resolvingSymlinksInPath().path == app
        }
        // Default for none of them (a chat app that merely accepts MP3s): Tab does nothing.
        guard !owned.isEmpty else { return nil }
        let chosen = Array(owned.prefix(40))
        let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        return SearchTag(
            keyword: "app:" + path.lowercased(), name: "\(name) files", urlTemplate: "", domain: nil,
            symbol: "doc.on.doc.fill", colors: "#a7aeb8,#5e6670", files: FileScope(extensions: chosen)
        )
    }
}
