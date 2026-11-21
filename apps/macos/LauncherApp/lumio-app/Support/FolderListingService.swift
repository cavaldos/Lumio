import Foundation

struct FolderEntry: Equatable {
    let name: String
    let isDir: Bool
    let size: Int64?
    /// When it was last changed (the list is newest first).
    var modified: Date? = nil
}

struct FolderListing: Equatable {
    let items: [FolderEntry]
    let folderCount: Int
    let fileCount: Int
    let truncated: Bool
}

enum FolderListingService {
    nonisolated static let listCap = 30

    static func list(path: String) async -> FolderListing? {
        await Task.detached(priority: .userInitiated) {
            listSync(path: path)
        }.value
    }

    nonisolated private static func listSync(path: String) -> FolderListing? {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return nil
        }

        // Newest first, folders and files together: what you just saved or exported is on top,
        // the way you would look for it.
        var folderCount = 0
        var fileCount = 0
        var found: [(name: String, url: URL, isDir: Bool, modified: Date)] = []
        for child in entries {
            let name = child.lastPathComponent
            if name.hasPrefix(".") { continue }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let isDir = values?.isDirectory ?? false
            if isDir { folderCount += 1 } else { fileCount += 1 }
            found.append((name, child, isDir, values?.contentModificationDate ?? .distantPast))
        }
        found.sort { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let total = folderCount + fileCount
        let items: [FolderEntry] = found.prefix(listCap).map { entry in
            let size = entry.isDir ? nil
                : (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init)
            return FolderEntry(
                name: entry.name, isDir: entry.isDir, size: size,
                modified: entry.modified == .distantPast ? nil : entry.modified
            )
        }

        return FolderListing(
            items: items,
            folderCount: folderCount,
            fileCount: fileCount,
            truncated: total > listCap
        )
    }
}
