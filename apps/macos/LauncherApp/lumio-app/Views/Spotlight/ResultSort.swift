//
//  ResultSort.swift
//  lumio-app
//
//  The sort menu (Fluent Search's "Sort by"): Default keeps Lumio's own order (best match,
//  what you picked before, most recent). The others reorder what is listed:
//    Name           everything with a name, A to Z
//    Date modified  files and folders, newest first; other rows stay below in their order
//    File size      files, largest first
//    Type           files grouped by extension, then by name
//

import Foundation

enum ResultSort: String, CaseIterable {
    case relevance, name, modified, size, kind

    var label: String {
        switch self {
        case .relevance: "Default"
        case .name: "Name"
        case .modified: "Date modified"
        case .size: "File size"
        case .kind: "Type"
        }
    }

    /// Date and size per path, read once per launcher session (see `forget`).
    private static var facts: [String: (date: Date, size: Int64)] = [:]

    private static func fact(_ path: String) -> (date: Date, size: Int64) {
        if let known = facts[path] { return known }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let value = (
            date: (attributes?[.modificationDate] as? Date) ?? .distantPast,
            size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        )
        facts[path] = value
        return value
    }

    /// Called when the launcher closes, so the next session reads fresh dates and sizes.
    static func forget() { facts.removeAll(keepingCapacity: true) }

    static func sorted(_ items: [SpotlightItem], by mode: ResultSort) -> [SpotlightItem] {
        switch mode {
        case .relevance:
            return items
        case .name:
            let nameable: Set<SpotlightKind> = [.app, .doc, .content, .folder, .url, .tab, .window, .setting]
            let named = items.filter { nameable.contains($0.kind) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return named + items.filter { !nameable.contains($0.kind) }
        case .modified, .size, .kind:
            let files = items.enumerated().filter { $0.element.isFileTarget }
            let rest = items.filter { !$0.isFileTarget }
            let ordered = files.sorted { lhs, rhs in
                let (a, b) = (lhs.element, rhs.element)
                let (fa, fb) = (fact(a.target ?? ""), fact(b.target ?? ""))
                switch mode {
                case .modified where fa.date != fb.date: return fa.date > fb.date
                case .size:
                    // Folders have no size of their own: after the files.
                    let (sa, sb) = (a.kind == .folder ? -1 : fa.size, b.kind == .folder ? -1 : fb.size)
                    if sa != sb { return sa > sb }
                case .kind:
                    let ea = a.kind == .folder ? "" : (a.name as NSString).pathExtension.lowercased()
                    let eb = b.kind == .folder ? "" : (b.name as NSString).pathExtension.lowercased()
                    if ea != eb { return ea < eb }
                    let order = a.name.localizedStandardCompare(b.name)
                    if order != .orderedSame { return order == .orderedAscending }
                default: break
                }
                return lhs.offset < rhs.offset
            }
            return ordered.map(\.element) + rest
        }
    }
}
