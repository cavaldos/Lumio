import XCTest

@testable import LauncherLogic

final class TabOrderTests: XCTestCase {
    func testDefaultOrderPutsOCRLast() {
        XCTAssertEqual(TabOrder.defaultCodes.last, "content")
        XCTAssertEqual(TabOrder.parse(""), TabOrder.defaultCodes)
    }

    func testASavedOrderIsKept() {
        let saved = "content,process,clip,lookup,translation"
        XCTAssertEqual(TabOrder.parse(saved), saved.split(separator: ",").map(String.init))
        XCTAssertEqual(TabOrder.render(TabOrder.parse(saved)), saved)
    }

    func testJunkAndRepeatsAreDroppedAndMissingTabsComeBack() {
        XCTAssertEqual(
            TabOrder.parse(" Process , bogus, process,,content"),
            ["process", "content", "clip", "lookup", "translation"])
    }

    func testMovingAtab() {
        let order = TabOrder.defaultCodes
        XCTAssertEqual(
            TabOrder.moving("content", by: -1, in: order),
            ["clip", "lookup", "translation", "content", "process"])
        XCTAssertEqual(
            TabOrder.moving("clip", by: 1, in: order),
            ["lookup", "clip", "translation", "process", "content"])
    }

    func testMovingPastAnEndChangesNothing() {
        let order = TabOrder.defaultCodes
        XCTAssertEqual(TabOrder.moving("clip", by: -1, in: order), order)
        XCTAssertEqual(TabOrder.moving("content", by: 1, in: order), order)
        XCTAssertEqual(TabOrder.moving("nope", by: 1, in: order), order)
    }
}
