import XCTest
@testable import LauncherLogic

@MainActor
final class DelayedActionTests: XCTestCase {
    private let delay = Duration.milliseconds(40)
    private let settle = UInt64(150_000_000)

    func testRunsAfterTheDelay() async {
        let action = DelayedAction()
        var ran = 0
        action.schedule(after: delay) { ran += 1 }
        XCTAssertEqual(ran, 0)
        try? await Task.sleep(nanoseconds: settle)
        XCTAssertEqual(ran, 1)
    }

    func testCancelBeforeTheDelayPreventsIt() async {
        let action = DelayedAction()
        var ran = 0
        action.schedule(after: delay) { ran += 1 }
        action.cancel()
        try? await Task.sleep(nanoseconds: settle)
        XCTAssertEqual(ran, 0)
    }

    func testRescheduleReplacesThePendingAction() async {
        let action = DelayedAction()
        var first = 0
        var second = 0
        action.schedule(after: delay) { first += 1 }
        action.schedule(after: delay) { second += 1 }
        try? await Task.sleep(nanoseconds: settle)
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
    }

    func testAFalseConditionAtWakeUpDropsTheAction() async {
        let action = DelayedAction()
        var visible = false
        var ran = 0
        action.schedule(after: delay, if: { !visible }) { ran += 1 }
        visible = true
        try? await Task.sleep(nanoseconds: settle)
        XCTAssertEqual(ran, 0)
    }
}
