import XCTest
@testable import MnomeSupport
final class DockTests: XCTestCase {
    func testFirstUseAndEmptyPersistence() {
        let name = UUID().uuidString; let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        let store = FavoritesStore(defaults: defaults); let seed = Favorite(id: "a", name: "A", path: "/A.app")
        XCTAssertEqual(store.load { [seed] }, [seed]); store.save([])
        XCTAssertEqual(store.load { [seed] }, [])
    }
    func testReorderingAndUnknownIDs() {
        let items = ["a", "b", "c"].map { Favorite(id: $0, name: $0, path: $0) }
        XCTAssertEqual(FavoritesStore.reordered(items, moving: "c", before: "a").map(\.id), ["c", "a", "b"])
        XCTAssertEqual(FavoritesStore.reordered(items, moving: "missing", before: "a"), items)
    }
    func testMoveToEnd() {
        let items = ["a", "b"].map { Favorite(id: $0, name: $0, path: $0) }
        XCTAssertEqual(FavoritesStore.movedToEnd(items, id: "a").map(\.id), ["b", "a"])
        XCTAssertEqual(FavoritesStore.movedToEnd(items, id: "unknown"), items)
    }
    func testResolutionFallbackAndMissing() {
        let favorite = Favorite(id: "a", name: "A", path: "/saved.app")
        XCTAssertEqual(FavoritesStore.resolvedPath(favorite, lookup: { _ in "/new.app" }, exists: { _ in true }), "/new.app")
        XCTAssertEqual(FavoritesStore.resolvedPath(favorite, lookup: { _ in nil }, exists: { $0 == "/saved.app" }), "/saved.app")
        XCTAssertNil(FavoritesStore.resolvedPath(favorite, lookup: { _ in nil }, exists: { _ in false }))
    }
    func testGeometryOverflowAndNegativeCoordinates() {
        let visible = CGRect(x: -1200, y: -200, width: 1200, height: 900)
        let rect = DockGeometry.frame(visible: visible, count: 100)
        XCTAssertEqual(rect.width, 1176); XCTAssertEqual(rect.minY, -192); XCTAssertTrue(visible.contains(rect))
    }
}
