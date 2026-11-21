import XCTest

@testable import LauncherLogic

final class QuickBubblesTests: XCTestCase {
    func testDefaultsAndEmpty() {
        XCTAssertEqual(QuickBubbles.parse(""), QuickBubbles.defaultCodes)
        XCTAssertEqual(QuickBubbles.defaultCodes.count, QuickBubbles.slotCount)
    }

    func testJunkRepeatsAndExtrasAreFixed() {
        XCTAssertEqual(QuickBubbles.parse(" Clip, bogus, clip, process"), ["clip", "process", "app", "folder"])
        XCTAssertEqual(QuickBubbles.parse("clip,lookup,translation,process,app"), ["clip", "lookup", "translation", "process"])
    }

    func testSettingASlotSwapsWhenTaken() {
        let d = QuickBubbles.defaultCodes  // app, folder, doc, content
        XCTAssertEqual(QuickBubbles.setting(slot: 0, to: "clip", in: d), ["clip", "folder", "doc", "content"])
        XCTAssertEqual(QuickBubbles.setting(slot: 0, to: "doc", in: d), ["doc", "folder", "app", "content"])
    }

    func testMovingASlot() {
        let d = QuickBubbles.defaultCodes
        XCTAssertEqual(QuickBubbles.moving(slot: 3, by: -1, in: d), ["app", "folder", "content", "doc"])
        XCTAssertEqual(QuickBubbles.moving(slot: 0, by: -1, in: d), d)
    }

    func testHiddenTabs() {
        XCTAssertEqual(TabOrder.parseHidden("Process, bogus, process"), ["process"])
        XCTAssertEqual(TabOrder.visible(order: TabOrder.defaultCodes, hidden: ["process", "clip"]), ["lookup", "translation", "content"])
        XCTAssertEqual(TabOrder.setting("clip", shown: false, in: []), ["clip"])
        XCTAssertEqual(TabOrder.setting("clip", shown: true, in: ["clip", "content"]), ["content"])
    }
}
