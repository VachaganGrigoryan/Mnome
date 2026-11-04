import XCTest
@testable import MnomeSupport
final class AppearanceTests: XCTestCase {
    func testMissingAndInvalidPreferenceFollowSystem() {
        XCTAssertEqual(AppearanceChoice.saved(nil), .system)
        XCTAssertEqual(AppearanceChoice.saved("invalid"), .system)
        XCTAssertEqual(AppearanceChoice.saved("Dark"), .dark)
        XCTAssertEqual(AppearanceChoice.saved("Light"), .light)
    }
    func testReorderBoundariesPreserveIdentity() {
        let values = [Favorite(id: "a", name: "A", path: "/a"), Favorite(id: "b", name: "B", path: "/b")]
        XCTAssertEqual(FavoritesStore.reordered(values, moving: "a", before: "a"), values)
        XCTAssertEqual(FavoritesStore.reordered(values, moving: "missing", before: "b"), values)
        XCTAssertEqual(FavoritesStore.reordered(values, moving: "b", before: "a").map(\.id), ["b", "a"])
    }
}
