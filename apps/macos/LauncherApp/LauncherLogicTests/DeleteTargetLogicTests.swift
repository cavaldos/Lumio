import XCTest
@testable import LauncherLogic

final class DeleteTargetLogicTests: XCTestCase {
    // MARK: - isProtected

    func testProtectsHomeRootAndTrash() {
        let home = "/Users/me"
        XCTAssertTrue(DeleteTargetLogic.isProtected("/", homeDirectory: home))
        XCTAssertTrue(DeleteTargetLogic.isProtected("", homeDirectory: home))
        XCTAssertTrue(DeleteTargetLogic.isProtected("/Users/me", homeDirectory: home))
        XCTAssertTrue(DeleteTargetLogic.isProtected("/Users/me/", homeDirectory: home))
        XCTAssertTrue(DeleteTargetLogic.isProtected("/Users/me/.Trash", homeDirectory: home))
        XCTAssertFalse(DeleteTargetLogic.isProtected("/Users/me/Projects", homeDirectory: home))
    }

    // MARK: - isQuickFolderPin

    func testRecognizesQuickFolderPins() {
        // Quick-folder pins are navigation shortcuts, not delete targets, even
        // though they're real, existing folders outside the protected set.
        let prefix = AppConstants.Launcher.QuickFolder.idPrefix
        XCTAssertTrue(DeleteTargetLogic.isQuickFolderPin("\(prefix)applications"))
        XCTAssertTrue(DeleteTargetLogic.isQuickFolderPin("\(prefix)documents"))
        XCTAssertFalse(DeleteTargetLogic.isQuickFolderPin("file:/Users/me/Projects"))
    }

    // MARK: - isURLScheme

    func testURLSchemePaths() {
        XCTAssertTrue(DeleteTargetLogic.isURLScheme("x-apple.systempreferences:com.apple.Wi-Fi"))
        XCTAssertFalse(DeleteTargetLogic.isURLScheme("/Users/me/a:b.txt"))
    }

    // MARK: - isTrashPath

    func testIsTrashPath() {
        let home = "/Users/me"
        XCTAssertTrue(DeleteTargetLogic.isTrashPath("/Users/me/.Trash", homeDirectory: home))
        XCTAssertTrue(DeleteTargetLogic.isTrashPath("/Users/me/.Trash/", homeDirectory: home))
        XCTAssertFalse(DeleteTargetLogic.isTrashPath("/Users/me/.Trash/file.txt", homeDirectory: home))
        XCTAssertFalse(DeleteTargetLogic.isTrashPath("/Users/me/Documents", homeDirectory: home))
    }

    // MARK: - empty trash wording

    func testEmptyTrashDetailPluralization() {
        XCTAssertEqual(DeleteTargetLogic.emptyTrashDetail(itemCount: 1), "1 item - deleted permanently")
        XCTAssertEqual(DeleteTargetLogic.emptyTrashDetail(itemCount: 7), "7 items - deleted permanently")
    }
}
