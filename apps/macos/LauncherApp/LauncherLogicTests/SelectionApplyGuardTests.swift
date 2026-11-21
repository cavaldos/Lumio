import XCTest
@testable import LauncherLogic

final class SelectionApplyGuardTests: XCTestCase {
    private let base = SelectionApplyGuard<String>(queryAtShow: "", browseAtShow: nil)

    private func apply(
        _ g: SelectionApplyGuard<String>? = nil,
        isOpen: Bool = true, dismissing: Bool = false, query: String = "",
        browse: String? = nil, inScope: Bool = false, hasActiveCommand: Bool = false
    ) -> Bool {
        (g ?? base).shouldApply(
            isOpen: isOpen, dismissing: dismissing, query: query, browse: browse,
            inScope: inScope, hasActiveCommand: hasActiveCommand
        )
    }

    func testAppliesWhenNothingChanged() { XCTAssertTrue(apply()) }
    func testClosedLauncherDropsIt() { XCTAssertFalse(apply(isOpen: false)) }
    func testDismissingLauncherDropsIt() { XCTAssertFalse(apply(dismissing: true)) }
    func testTypingDropsIt() { XCTAssertFalse(apply(query: "a")) }
    func testPickingATabDropsIt() { XCTAssertFalse(apply(browse: "clip")) }
    func testScopeOrCommandDropsIt() {
        XCTAssertFalse(apply(inScope: true))
        XCTAssertFalse(apply(hasActiveCommand: true))
    }

    /// A kept search or tab restored by show() is the baseline, not user input.
    func testRestoredQueryAndTabAreTheBaseline() {
        let g = SelectionApplyGuard(queryAtShow: "kept", browseAtShow: "lookup")
        XCTAssertTrue(apply(g, query: "kept", browse: "lookup"))
        XCTAssertFalse(apply(g, query: "kept!", browse: "lookup"))
    }
}
