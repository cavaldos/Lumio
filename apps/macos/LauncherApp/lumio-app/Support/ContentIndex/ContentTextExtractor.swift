import CoreGraphics
import ImageIO
import OSLog
import PDFKit
import Vision

nonisolated private let extractLog = Logger(subsystem: "com.cavaldos.Lumio", category: "ContentIndex")

/// Reads the text inside images and PDFs: OCR (Vision) for images, scanned pages and pictures
/// inside PDFs, plus the PDF text layer. Runs on the indexer's background task.
nonisolated enum ContentTextExtractor {
    /// Larger files are skipped: reading them costs too much for a launcher.
    static let maxImageBytes: Int64 = 40 << 20
    static let maxPDFBytes: Int64 = 200 << 20
    /// Smaller images are icons, never documents.
    static let minImageSide = 48
    /// Long side the image is scaled down to before OCR (keeps memory and time bounded).
    static let ocrMaxPixelSide = 3000
    static let maxPDFPages = 300
    /// PDF pages that need OCR (scans, pages with pictures), at most this many per file.
    static let maxOCRPages = 15
    /// A text layer shorter than this is a scan with a page number / stamp on top: OCR it anyway.
    static let sparseTextLayer = 80
    /// Embedded pictures at least this big (pixels) may hold text: screenshots, photos of documents.
    static let minEmbeddedImageSide = 150
    static let minEmbeddedImagePixels = 100_000

    static func canRead(_ url: URL) -> Bool {
        ContentSearchText.isIndexable(extension: url.pathExtension)
    }

    /// The file's text, or nil when it can't be read / has none / is too large.
    static func text(of url: URL, size: Int64) async -> String? {
        let ext = url.pathExtension.lowercased()
        if ContentSearchText.imageExtensions.contains(ext) {
            guard size <= maxImageBytes, let image = loadImage(url) else { return nil }
            return await recognize(image)
        }
        if ContentSearchText.pdfExtensions.contains(ext) {
            guard size <= maxPDFBytes else { return nil }
            return await pdfText(url)
        }
        return nil
    }

    // MARK: - PDF

    private static func pdfText(_ url: URL) async -> String? {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        let limit = ContentIndexStore.maxStoredCharacters
        var parts: [String] = []
        var total = 0
        var ocrPages = 0
        for index in 0..<min(document.pageCount, maxPDFPages) {
            guard total < limit, !Task.isCancelled else { break }
            let canOCR = ocrPages < maxOCRPages
            // PDFKit autoreleases per page; drain it page by page, not once per file.
            var (pageText, scan): (String, CGImage?) = autoreleasepool {
                guard let page = document.page(at: index) else { return ("", nil) }
                let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // OCR the page when its text layer can't be the whole story: a scan (no or almost
                // no text) or a page with pictures that may hold text (screenshots, photos).
                let needsOCR = text.count < sparseTextLayer
                    || page.pageRef.map(hasPicture(on:)) == true
                return (text, canOCR && needsOCR ? render(page) : nil)
            }
            if let image = scan {
                ocrPages += 1
                scan = nil
                if let recognized = await recognize(image) {
                    pageText = merge(textLayer: pageText, ocr: recognized)
                }
            }
            guard !pageText.isEmpty else { continue }
            parts.append(pageText)
            total += pageText.count
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// The text layer is exact; OCR adds only the lines it doesn't already contain (the text
    /// inside pictures), so the stored text and snippets don't repeat every line twice.
    private static func merge(textLayer: String, ocr: String) -> String {
        guard !textLayer.isEmpty else { return ocr }
        let known = ContentSearchText.fold(textLayer)
        let extra = ocr.split(separator: "\n").filter { line in
            let folded = ContentSearchText.fold(String(line))
            return !folded.isEmpty && !known.contains(folded)
        }
        return extra.isEmpty ? textLayer : textLayer + "\n" + extra.joined(separator: "\n")
    }

    /// True when the page draws a picture big enough to contain text (looks in its XObjects,
    /// and in nested forms a few levels down).
    private static func hasPicture(on page: CGPDFPage) -> Bool {
        guard let dict = page.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return false }
        return containsPicture(resources, depth: 0)
    }

    private final class Flag { var value = false }

    private static func containsPicture(_ resources: CGPDFDictionaryRef, depth: Int) -> Bool {
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return false }
        let found = Flag()
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let info = CGPDFStreamGetDictionary(stream)
            else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(info, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image":
                var width: CGPDFInteger = 0
                var height: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(info, "Width", &width)
                CGPDFDictionaryGetInteger(info, "Height", &height)
                if min(width, height) >= minEmbeddedImageSide, width * height >= minEmbeddedImagePixels {
                    found.value = true
                }
            case "Form" where depth < 3:
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(info, "Resources", &nested), let nested,
                   containsPicture(nested, depth: depth + 1)
                {
                    found.value = true
                }
            default:
                break
            }
            return !found.value
        }, nil)
        return found.value
    }

    /// Draws a PDF page at ~2x (144 dpi), white background, for OCR.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2, CGFloat(ocrMaxPixelSide) / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: - Images

    /// Decodes the image already scaled down (ImageIO thumbnail), so a 50 MP photo never sits
    /// in memory at full size.
    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard min(width, height) >= minImageSide else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), ocrMaxPixelSide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - OCR

    private static func recognize(_ image: CGImage) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Vietnamese, English, … picked per image.
        request.automaticallyDetectsLanguage = true
        do {
            let observations = try await request.perform(on: image)
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        } catch {
            extractLog.debug("OCR failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
