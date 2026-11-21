import XCTest

@testable import LauncherLogic

final class ClipboardLimitsTests: XCTestCase {
    private let key = AppConstants.Launcher.Clipboard.historyLimitConfigKey
    private let imageKey = AppConstants.Launcher.ClipboardImage.limitConfigKey

    func testTheDefaultHistoryIs300() {
        XCTAssertEqual(AppConstants.Launcher.Clipboard.maxEntries, 300)
        XCTAssertEqual(ClipboardLimits.historyLimit(from: [:]), 300)
    }

    func testAnInRangeLimitIsHonoredWhitespaceIncluded() {
        XCTAssertEqual(ClipboardLimits.historyLimit(from: [key: "10"]), 10)
        XCTAssertEqual(ClipboardLimits.historyLimit(from: [key: " 450 "]), 450)
        // An existing config written by an older build keeps the 1000 it asked for.
        XCTAssertEqual(ClipboardLimits.historyLimit(from: [key: "1000"]), 1000)
    }

    func testAnOutOfRangeOrUnreadableLimitFallsBackToTheDefaultNotTheNearestBound() {
        for raw in ["9", "0", "-5", "1001", "5000", "many", ""] {
            XCTAssertEqual(ClipboardLimits.historyLimit(from: [key: raw]), 300, raw)
        }
    }

    func testTheImageLimitHasItsOwnRangeAndDefault() {
        XCTAssertEqual(ClipboardLimits.imageLimit(from: [:]), 20)
        XCTAssertEqual(ClipboardLimits.imageLimit(from: [imageKey: "5"]), 5)
        XCTAssertEqual(ClipboardLimits.imageLimit(from: [imageKey: "50"]), 50)
        XCTAssertEqual(ClipboardLimits.imageLimit(from: [imageKey: "51"]), 20)
        XCTAssertEqual(ClipboardLimits.imageLimit(from: [imageKey: "4"]), 20)
        // The text limit does not leak into the image one.
        XCTAssertEqual(ClipboardLimits.imageLimit(from: [key: "100"]), 20)
    }

    /// The core keeps its own backstop; a limit the UI allows must fit under it.
    func testTheLargestAllowedHistoryIsWithinWhatTheCoreStores() {
        XCTAssertEqual(ClipboardLimits.textRange.upperBound, 1000)
    }
}

final class ClipboardTextTests: XCTestCase {
    func testTitleCollapsesLinesAndElidesLongText() {
        XCTAssertEqual(ClipboardText.title(from: "  one\r\ntwo\nthree  "), "one two three")
        let long = String(repeating: "a", count: 200)
        let title = ClipboardText.title(from: long)
        XCTAssertEqual(title.count, AppConstants.Launcher.Clipboard.maxTitleCharacters + 1)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(ClipboardText.title(from: " \n "), AppConstants.Launcher.Clipboard.emptyEntryTitle)
    }

    func testLineCountMatchesTheCoresRule() {
        XCTAssertEqual(ClipboardText.lineCount(of: "one"), 1)
        XCTAssertEqual(ClipboardText.lineCount(of: "one\n"), 1)
        XCTAssertEqual(ClipboardText.lineCount(of: "a\nb"), 2)
        XCTAssertEqual(ClipboardText.lineCount(of: "a\r\nb\r\nc"), 3)
        XCTAssertEqual(ClipboardText.lineCount(of: "a\rb\rc"), 3)
        XCTAssertEqual(ClipboardText.lineCount(of: "a\n\nb"), 3)
        XCTAssertEqual(ClipboardText.lineCount(of: "a\n\n"), 2)
        XCTAssertEqual(ClipboardText.lineCount(of: "\n"), 1)
    }

    func testPreviewIsShortAndSkipsLeadingBlankSpace() {
        let long = "\n\n  " + String(repeating: "x", count: 5_000)
        let preview = ClipboardText.preview(of: long)
        XCTAssertEqual(preview.count, AppConstants.Launcher.Clipboard.previewCharacters)
        XCTAssertTrue(preview.hasPrefix("x"))
        // A short clip is kept whole (minus the leading blanks).
        XCTAssertEqual(ClipboardText.preview(of: "  hello"), "hello")
    }

    /// The row title must come out the same from the preview as from the whole clip,
    /// or a restart would relabel every long clip in the list.
    func testTheTitleOfAPreviewMatchesTheTitleOfTheWholeClip() {
        let whole = "first line\r\nsecond line " + String(repeating: "y", count: 4_000)
        XCTAssertEqual(
            ClipboardText.title(from: ClipboardText.preview(of: whole)),
            ClipboardText.title(from: whole))
    }
}

final class ClipboardContentKeyTests: XCTestCase {
    /// The same three values are pinned in core/storage's tests (`content_hash`): the
    /// Swift side must reproduce them or a fresh copy would not match a stored row. The
    /// core's multiplier is 0x1000_0000_01b3, not the textbook FNV prime; it is kept
    /// as is because every stored row is identified by it.
    func testItReproducesTheCoresDedupeHash() {
        XCTAssertEqual(ClipboardContentKey.make(for: ""), "cbf29ce484222325")
        XCTAssertEqual(ClipboardContentKey.make(for: "a"), "af74d84c8601ec8c")
        XCTAssertEqual(ClipboardContentKey.make(for: "foobar"), "f8ac2471f73967e8")
    }

    func testSurroundingWhitespaceDoesNotChangeTheKey() {
        XCTAssertEqual(
            ClipboardContentKey.make(for: "  hello\n"), ClipboardContentKey.make(for: "hello"))
        XCTAssertNotEqual(
            ClipboardContentKey.make(for: "hello"), ClipboardContentKey.make(for: "hellp"))
    }

    func testTheKeyIsAlwaysSixteenHexDigits() {
        for text in ["", "a", "short", String(repeating: "z", count: 30_000)] {
            let key = ClipboardContentKey.make(for: text)
            XCTAssertEqual(key.count, 16)
            XCTAssertNotNil(UInt64(key, radix: 16))
        }
    }
}
