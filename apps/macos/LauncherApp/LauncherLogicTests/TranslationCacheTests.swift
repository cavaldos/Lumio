import XCTest
@testable import LauncherLogic

final class TranslationCacheTests: XCTestCase {
    private let hello = TextTranslation(text: "xin chào", engine: .google)

    func testReturnsWhatWasStored() {
        let cache = TranslationCache(capacity: 10)
        let key = TranslationCache.key("hello", sourceID: "en", targetCode: "vi")
        XCTAssertNil(cache.get(key))
        cache.set(key, hello)
        XCTAssertEqual(cache.get(key), hello)
    }

    func testKeySeparatesSourceTargetAndText() {
        let base = TranslationCache.key("hello", sourceID: "en", targetCode: "vi")
        XCTAssertNotEqual(base, TranslationCache.key("hello", sourceID: "fr", targetCode: "vi"))
        XCTAssertNotEqual(base, TranslationCache.key("hello", sourceID: "en", targetCode: "fr"))
        XCTAssertNotEqual(base, TranslationCache.key("hello!", sourceID: "en", targetCode: "vi"))
        XCTAssertNotEqual(base, TranslationCache.key("hello", sourceID: nil, targetCode: "vi"))
    }

    func testEvictsOldestBeyondCapacity() {
        let cache = TranslationCache(capacity: 2)
        cache.set("a", hello)
        cache.set("b", hello)
        cache.set("a", TextTranslation(text: "updated", engine: .apple))  // update keeps its slot
        cache.set("c", hello)
        XCTAssertNil(cache.get("a"))
        XCTAssertEqual(cache.get("b"), hello)
        XCTAssertEqual(cache.get("c"), hello)
    }

    func testRemoveAll() {
        let cache = TranslationCache(capacity: 4)
        cache.set("a", hello)
        cache.removeAll()
        XCTAssertNil(cache.get("a"))
    }
}
