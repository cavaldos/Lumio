import XCTest
@testable import LauncherLogic

final class LauncherSearchLogicTests: XCTestCase {
    private var testSandboxURL: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()

        let folderName = "LauncherLogicTests-\(UUID().uuidString)"
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        testSandboxURL = sandboxURL
    }

    override func tearDownWithError() throws {
        if let sandboxURL = testSandboxURL,
           FileManager.default.fileExists(atPath: sandboxURL.path)
        {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
        testSandboxURL = nil

        try super.tearDownWithError()
    }

    func testPinnedScopeDetection() {
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "finder"), .unscoped)
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "a\"finder"), .apps)
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "f\"report"), .files)
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "d\"doc"), .folders)
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "r\".*"), .disabled)
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "c\"note"), .disabled)
        // rc" (recent) suppresses pinned quick-folder/Finder injection.
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "rc\""), .disabled)
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "rc\"report"), .disabled)
    }

    func testNormalizedPinnedQueryRespectsScope() {
        XCTAssertEqual(
            LauncherSearchLogic.normalizedPinnedLookupQuery(for: "a\" Finder ", scope: .apps),
            "finder"
        )
        XCTAssertEqual(
            LauncherSearchLogic.normalizedPinnedLookupQuery(for: "d\" Documents ", scope: .folders),
            "documents"
        )
        XCTAssertNil(
            LauncherSearchLogic.normalizedPinnedLookupQuery(for: "r\"foo", scope: .disabled)
        )
        XCTAssertNil(
            LauncherSearchLogic.normalizedPinnedLookupQuery(for: "   ", scope: .unscoped)
        )
    }

    func testFinderInjectionOnlyForAllowedScopes() {
        XCTAssertTrue(LauncherSearchLogic.shouldInjectFinder(normalizedQuery: "find", scope: .unscoped))
        XCTAssertTrue(LauncherSearchLogic.shouldInjectFinder(normalizedQuery: "finder", scope: .apps))
        XCTAssertFalse(LauncherSearchLogic.shouldInjectFinder(normalizedQuery: "finder", scope: .files))
        XCTAssertFalse(LauncherSearchLogic.shouldInjectFinder(normalizedQuery: "finder", scope: .folders))
        XCTAssertFalse(LauncherSearchLogic.shouldInjectFinder(normalizedQuery: "fi", scope: .unscoped))
        XCTAssertFalse(LauncherSearchLogic.shouldInjectFinder(normalizedQuery: nil, scope: .apps))
    }
}
