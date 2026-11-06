import XCTest

@testable import LauncherLogic

final class ContentIndexWorkerMessageTests: XCTestCase {
    func testEveryMessageSurvivesTheRoundTrip() {
        for message in [
            ContentIndexWorkerMessage.pending(0),
            .pending(1234),
            .reading("/Users/me/Desktop/Hóa đơn.pdf"),
        ] {
            XCTAssertEqual(ContentIndexWorkerMessage(line: message.line), message)
        }
    }

    func testAMessageIsExactlyOneLine() {
        // A file name may contain a newline; it must not split the message in two.
        let message = ContentIndexWorkerMessage.reading("/tmp/two\nlines.png")
        XCTAssertEqual(message.line.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(message.line.hasSuffix("\n"))
        XCTAssertEqual(ContentIndexWorkerMessage(line: message.line), message)
    }

    func testAnythingElseIsIgnored() {
        for line in ["", "   ", "pending 3", "{}", "{\"file\":\"\"}", "{not json", "2026-11-06 Vision: warming up"] {
            XCTAssertNil(ContentIndexWorkerMessage(line: line), line)
        }
    }

    func testANegativeCountReadsAsZero() {
        XCTAssertEqual(ContentIndexWorkerMessage(line: "{\"pending\":-4}"), .pending(0))
    }
}
