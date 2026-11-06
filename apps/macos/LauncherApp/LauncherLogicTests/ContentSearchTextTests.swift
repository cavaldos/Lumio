import XCTest

@testable import LauncherLogic

/// Folding, FTS query and snippet rules of the content (OCR / PDF text) search.
final class ContentSearchTextTests: XCTestCase {
    func testFoldDropsCaseDiacriticsAndCollapsesWhitespace() {
        XCTAssertEqual(ContentSearchText.fold("  Hóa ĐƠN\n\ttháng   Mười "), "hoa don thang muoi")
        XCTAssertEqual(ContentSearchText.fold("Café Résumé"), "cafe resume")
        XCTAssertEqual(ContentSearchText.fold(""), "")
    }

    func testMatchExpressionKeepsWordsTheTrigramIndexCanFind() {
        XCTAssertEqual(ContentSearchText.matchExpression(for: "Hóa đơn số 5"), "\"hoa\" \"don\"")
        XCTAssertNil(ContentSearchText.matchExpression(for: "ab"))
        XCTAssertNil(ContentSearchText.matchExpression(for: "a b c"))
        // A quote in the text can't break out of the FTS string.
        XCTAssertEqual(ContentSearchText.matchExpression(for: "say\"hi"), "\"say\"\"hi\"")
    }

    func testSnippetShowsOriginalTextAroundTheMatch() {
        let text = "Công ty ABC\nHóa đơn GTGT\nTổng cộng: 1.250.000 đ"
        XCTAssertEqual(
            ContentSearchText.snippet(in: text, query: "hoa don", radius: 4),
            "…ABC Hóa đơn GTG…")
        XCTAssertEqual(
            ContentSearchText.snippet(in: text, query: "tong cong", radius: 100),
            "Công ty ABC Hóa đơn GTGT Tổng cộng: 1.250.000 đ")
    }

    func testSnippetFallsBackToTheLongestWord() {
        let text = "Invoice for October services"
        XCTAssertEqual(
            ContentSearchText.snippet(in: text, query: "october invoice", radius: 3),
            "…or October se…")
        XCTAssertNil(ContentSearchText.snippet(in: text, query: "receipt"))
    }

    func testIndexableExtensions() {
        for ext in ["PNG", "jpg", "jpeg", "heic", "pdf", "PDF"] {
            XCTAssertTrue(ContentSearchText.isIndexable(extension: ext), ext)
        }
        // Text files are not OCR material.
        for ext in ["md", "txt", "docx", "rtf", "csv", "app", "zip", "swift", "mp4", ""] {
            XCTAssertFalse(ContentSearchText.isIndexable(extension: ext), ext)
        }
    }
}

@MainActor
final class ContentIndexConfigTests: XCTestCase {
    private let home = "/Users/test"

    func testDefaults() {
        let config = ContentIndexConfig.from(keyValues: [:], home: home)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.roots, ["/Users/test/Desktop", "/Users/test/Documents", "/Users/test/Downloads"])
        XCTAssertEqual(config.limit, ContentIndexConfig.defaultLimit)
        XCTAssertTrue(config.skipDirNames.contains("node_modules"))
    }

    func testReadsTheFileIndexKeysAndItsOwn() {
        let config = ContentIndexConfig.from(keyValues: [
            "content_index_enabled": "false",
            "content_index_limit": "999999",
            "file_scan_roots": "Documents,/",
            "file_scan_extra_roots": "~/Pictures",
            "file_exclude_paths": "~/Documents/private",
            "file_scan_depth": "2",
        ], home: home)
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.limit, ContentIndexConfig.limitRange.upperBound)
        XCTAssertEqual(config.depth, 2)
        // "/" is refused: OCR'ing a whole disk is not a launcher's job.
        XCTAssertEqual(config.roots, ["/Users/test/Documents", "/Users/test/Pictures"])
        XCTAssertTrue(config.isExcluded("/Users/test/Documents/private"))
        XCTAssertTrue(config.isExcluded("/Users/test/Documents/private/scan.pdf"))
        XCTAssertFalse(config.isExcluded("/Users/test/Documents/private-notes.pdf"))
    }
}
