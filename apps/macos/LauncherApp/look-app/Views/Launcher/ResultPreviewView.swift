import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ResultPreviewView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let result: LauncherResult
    var onDeleteClipboard: (() -> Void)? = nil
    /// Process-finder preview inputs (only set for `.process` results).
    var processDetail: ProcessDetail? = nil
    var processCPU: Double? = nil
    var isMeasuringProcessCPU: Bool = false
    /// The Cmd+K action menu, floated under the header rather than laid out.
    var isActionMenuOpen: Bool = false
    var actionMenuIndex: Int = 0
    var actionMenuDescriptors: [LauncherView.RowActionDescriptor] = []
    var onActivateActionMenuRow: (LauncherView.RowActionDescriptor) -> Void = { _ in }

    @State private var folderListing: FolderListing?
    @State private var trashItemCount: Int?

    /// The menu for a preview that has no content area to pin it into.
    @ViewBuilder
    private var floatingActionMenu: some View {
        if isActionMenuOpen {
            actionMenu
                .padding(.horizontal, 16)
                .padding(.top, 84)
        }
    }

    private var actionMenu: some View {
        ActionMenuView(
            descriptors: actionMenuDescriptors,
            focusedIndex: actionMenuIndex,
            themeStore: themeStore,
            onActivate: onActivateActionMenuRow
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
        .zIndex(1)
    }

    /// A System Settings pane result (its "path" is a URL scheme, not a file).
    private var isSetting: Bool {
        result.id.hasPrefix("setting:")
    }

    /// The pinned Trash quick folder is TCC-protected, so it can't be listed
    /// like a normal folder - it gets a Finder-backed summary instead.
    private var isTrash: Bool {
        result.kind == .folder
            && DeleteTargetLogic.isTrashPath(result.path, homeDirectory: NSHomeDirectory())
    }

    private func folderCountText(_ listing: FolderListing) -> String? {
        var parts: [String] = []
        if listing.folderCount > 0 {
            parts.append("\(listing.folderCount) folder\(listing.folderCount == 1 ? "" : "s")")
        }
        if listing.fileCount > 0 {
            parts.append("\(listing.fileCount) file\(listing.fileCount == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static let modifiedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    private static let clipboardDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private var clipboardIcon: NSImage {
        NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            ?? NSWorkspace.shared.icon(for: .plainText)
    }

    private var largeIcon: NSImage {
        if result.id.hasPrefix("setting:") {
            let settingsPath = "/System/Applications/System Settings.app"
            if FileManager.default.fileExists(atPath: settingsPath) {
                return NSWorkspace.shared.icon(forFile: settingsPath)
            }
            let legacyPath = "/System/Applications/System Preferences.app"
            return NSWorkspace.shared.icon(forFile: legacyPath)
        }
        return NSWorkspace.shared.icon(forFile: result.path)
    }

    private var bundleInfo: (version: String?, size: String, modified: String?) {
        var version: String? = nil
        var modified: String? = nil
        var totalSize: Int64 = 0

        if result.id.hasPrefix("setting:") || result.kind == .app {
            let appPath = result.id.hasPrefix("setting:")
                ? "/System/Applications/System Settings.app"
                : result.path

            if let bundle = Bundle(path: appPath) {
                version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
                    ?? bundle.infoDictionary?["CFBundleVersion"] as? String
            }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: appPath) {
                if let modDate = attrs[.modificationDate] as? Date {
                    modified = Self.modifiedDateFormatter.string(from: modDate)
                }
                if let size = attrs[.size] as? Int64 {
                    totalSize = size
                }
            }
        } else {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: result.path) {
                if let size = attrs[.size] as? Int64 {
                    totalSize = size
                }
                if let modDate = attrs[.modificationDate] as? Date {
                    modified = Self.modifiedDateFormatter.string(from: modDate)
                }
            }
        }

        let sizeStr = formatFileSize(totalSize)
        return (version, sizeStr, modified)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    var body: some View {
        if result.kind == .action {
            genericActionPreview.overlay(alignment: .top) { floatingActionMenu }
        } else if result.kind == .process {
            processPreview
        } else if result.isClipboardImage {
            clipboardImagePreview
        } else if result.kind == .clipboard {
            clipboardPreview
        } else {
        let info = bundleInfo

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: largeIcon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title)
                            .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize + 2), weight: .semibold))
                            .foregroundStyle(themeStore.fontColor())
                            .lineLimit(2)

                        HStack(spacing: 6) {
                            KindBadge(kind: result.kind.rawValue)
                            if result.kind == .folder {
                                if isTrash {
                                    if let trashItemCount {
                                        Text("\(trashItemCount) item\(trashItemCount == 1 ? "" : "s")")
                                            .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                                            .foregroundStyle(themeStore.secondaryTextColor())
                                    }
                                } else if let listing = folderListing,
                                   let counts = folderCountText(listing) {
                                    Text(counts)
                                        .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                                        .foregroundStyle(themeStore.secondaryTextColor())
                                }
                            } else {
                                Text(info.size)
                                    .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                                    .foregroundStyle(themeStore.secondaryTextColor())
                            }
                        }
                    }
                    Spacer()
                }

                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 12) {
                if result.kind == .file {
                    FilePreview(path: result.path)
                }

                if result.kind == .folder {
                    if isTrash {
                        TrashSummaryView(itemCount: trashItemCount, themeStore: themeStore)
                    } else {
                        FolderPreviewView(path: result.path, listing: folderListing)
                    }
                }

                if let version = info.version {
                    InfoRow(label: "Version", value: version)
                }

                if !isSetting {
                    InfoRow(label: "Path", value: result.path, truncation: .middle)

                    if let modified = info.modified {
                        InfoRow(label: "Modified", value: modified)
                    }
                }

                if result.kind != .file && result.kind != .folder {
                    Spacer()
                }
                    }

                    if isActionMenuOpen {
                        actionMenu
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: result.kind == .folder ? result.path : "") {
                guard result.kind == .folder else {
                    folderListing = nil
                    trashItemCount = nil
                    return
                }
                if isTrash {
                    folderListing = nil
                    trashItemCount = EmptyTrashCommand.itemCount(promptIfNeeded: false)
                    return
                }
                folderListing = nil
                let path = result.path
                let listing = await FolderListingService.list(path: path)
                if Task.isCancelled { return }
                folderListing = listing
            }
        }
    }

    /// Generic action row panel (no declared steps anymore).
    private var genericActionPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(themeStore.accentColor())
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize + 2), weight: .semibold))
                        .foregroundStyle(themeStore.fontColor())
                        .lineLimit(2)
                    Text(result.subtitle ?? "")
                        .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                        .foregroundStyle(themeStore.secondaryTextColor())
                }
                Spacer()
            }
            Spacer(minLength: 0)
            hintRow(key: "↵", text: "Run")
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func hintRow(key: String, text: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .semibold))
                .foregroundStyle(themeStore.accentColor())
                .frame(minWidth: 36)
                .padding(.vertical, 4)
                .background(themeStore.controlFillColor(), in: RoundedRectangle(cornerRadius: themeStore.chipRadius, style: .continuous))
            Text(text)
                .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 1), weight: .medium))
                .foregroundStyle(themeStore.secondaryTextColor())
        }
        .frame(width: 230, alignment: .leading)
    }

    /// Shared by the text and image panels.
    private func clipboardPreviewHeader(icon: NSImage, title: String) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .foregroundStyle(themeStore.accentColor())
            Text(title)
                .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize + 1), weight: .semibold))
                .foregroundStyle(themeStore.fontColor())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()

            if let onDeleteClipboard {
                Button {
                    onDeleteClipboard()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .semibold))
                        .foregroundStyle(themeStore.onDangerColor())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(themeStore.dangerColor(), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var clipboardPreview: some View {
        let content = result.clipboardContent ?? ""
        let capturedAt = result.clipboardCapturedAt.map { Self.clipboardDateFormatter.string(from: $0) } ?? "Unknown"
        let characterCount = result.clipboardCharacterCount ?? content.count
        let lineCount = result.clipboardLineCount ?? max(1, content.split(whereSeparator: \.isNewline).count)
        let previewFont = NSFont.monospacedSystemFont(
            ofSize: CGFloat(themeStore.settings.fontSize - 1),
            weight: .regular
        )

        return VStack(alignment: .leading, spacing: 10) {
            clipboardPreviewHeader(icon: clipboardIcon, title: "Clipboard item")

            HStack(spacing: 8) {
                KindBadge(kind: "clipboard")
                Text("\(characterCount) chars")
                    .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                    .foregroundStyle(themeStore.secondaryTextColor())
                Text("\(lineCount) lines")
                    .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                    .foregroundStyle(themeStore.secondaryTextColor())
            }

            Text("Preview")
                .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .medium))
                .foregroundStyle(themeStore.mutedTextColor())

            HighlightedTextView(
                attributed: NSAttributedString(string: content),
                font: previewFont,
                defaultColor: NSColor(themeStore.secondaryTextColor())
            )
            .background(themeStore.controlFillColor(), in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous))

            InfoRow(label: "Captured", value: capturedAt)

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var clipboardImagePreview: some View {
        let capturedAt =
            result.clipboardCapturedAt.map { Self.clipboardDateFormatter.string(from: $0) }
            ?? "Unknown"
        let image = result.clipboardImagePath.flatMap { NSImage(contentsOfFile: $0) }
        let pixelSize = result.clipboardImagePixelSize

        return VStack(alignment: .leading, spacing: 10) {
            clipboardPreviewHeader(icon: clipboardImageIcon, title: result.title)

            HStack(spacing: 8) {
                KindBadge(kind: "image")
                if let pixelSize {
                    Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
                        .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                        .foregroundStyle(themeStore.secondaryTextColor())
                }
                if let byteSize = result.clipboardImageByteSize {
                    Text(formatFileSize(Int64(byteSize)))
                        .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                        .foregroundStyle(themeStore.secondaryTextColor())
                }
            }

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        themeStore.controlFillColor(),
                        in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous))
            } else {
                Text("The image is no longer on disk")
                    .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 1), weight: .regular))
                    .foregroundStyle(themeStore.mutedTextColor())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            InfoRow(label: "Captured", value: capturedAt)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var clipboardImageIcon: NSImage {
        NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
            ?? clipboardIcon
    }

    private var processIcon: NSImage {
        result.processPID.map(LauncherProcessFeature.icon) ?? NSWorkspace.shared.icon(for: .unixExecutable)
    }

    private func formattedStart(_ epoch: UInt64) -> String {
        Self.modifiedDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    private var cpuValueText: String {
        if let processCPU {
            return String(format: "%.1f%%", processCPU)
        }
        return isMeasuringProcessCPU ? "Measuring…" : "Press Enter to measure"
    }

    private var portsText: String {
        let ports = result.processPorts ?? []
        return ports.isEmpty ? "None" : ports.map { ":\($0)" }.joined(separator: "  ")
    }

    private var processPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: processIcon)
                    .resizable()
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize + 2), weight: .semibold))
                        .foregroundStyle(themeStore.fontColor())
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        KindBadge(kind: "process")
                        if let pid = result.processPID {
                            Text("PID \(pid)")
                                .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                                .foregroundStyle(themeStore.secondaryTextColor())
                        }
                    }
                }
                Spacer()
            }

            if let detail = processDetail, !detail.cmdline.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Command")
                        .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                        .foregroundStyle(themeStore.mutedTextColor())
                    Text(detail.cmdline)
                        .font(.system(size: CGFloat(themeStore.settings.fontSize - 2), design: .monospaced))
                        .foregroundStyle(themeStore.secondaryTextColor())
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }

            if let detail = processDetail {
                InfoRow(label: "Memory", value: formatFileSize(Int64(detail.memoryKB) * 1024))
                if !detail.user.isEmpty {
                    InfoRow(label: "User", value: detail.user)
                }
                InfoRow(label: "Parent PID", value: String(detail.ppid))
                if let start = detail.startEpoch {
                    InfoRow(label: "Started", value: formattedStart(start))
                }
            }

            InfoRow(label: "CPU", value: cpuValueText)
            InfoRow(label: "Ports", value: portsText)

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct KindBadge: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let kind: String

    private var color: Color {
        switch kind {
        case "app": return themeStore.accentColor()
        case "file": return themeStore.successColor()
        case "folder": return themeStore.warningColor()
        case "clipboard", "image": return themeStore.accentColor()
        default: return themeStore.mutedTextColor()
        }
    }

    private var foreground: Color {
        switch kind {
        case "file":
            return themeStore.onSuccessColor()
        case "folder":
            return themeStore.onWarningColor()
        default:
            return themeStore.onAccentColor()
        }
    }

    var body: some View {
        Text(kind.capitalized)
            .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 3), weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.8), in: Capsule())
    }
}

struct InfoRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let label: String
    let value: String
    var truncation: Text.TruncationMode = .tail

    var body: some View {
        HStack {
            Text(label)
                .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                .foregroundStyle(themeStore.mutedTextColor())
            Spacer()
            Text(value)
                .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                .foregroundStyle(themeStore.secondaryTextColor())
                .lineLimit(1)
                .truncationMode(truncation)
        }
    }
}
