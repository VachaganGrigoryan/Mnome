import XCTest
@testable import MnomeSupport

final class MemoryStore: PreferenceStore {
    var values: [String: PrefValue]
    init(_ values: [String: PrefValue]) { self.values = values }
    func get(_ domain: String, _ key: String) -> PrefValue { values["\(domain)|\(key)"] ?? .absent }
    func set(_ domain: String, _ key: String, _ value: PrefValue) {
        if value == .absent { values["\(domain)|\(key)"] = nil } else { values["\(domain)|\(key)"] = value }
    }
}
final class MacChromeTests: XCTestCase {
    func initial() -> [String: PrefValue] {
        ["com.apple.dock|autohide": .bool(true), "com.apple.dock|autohide-delay": .int(0), "NSGlobalDomain|_HIHideMenuBar": .bool(false),
         "com.apple.WindowManager|GloballyEnabled": .bool(false)]
    }
    func testHideThenRestoreReturnsExactInitialState() {
        let store = MemoryStore(initial()); var snapshot = MacChromeSnapshot()
        for element in MacElement.allCases { snapshot.hide(element, store: store) }
        XCTAssertEqual(store.get("com.apple.dock", "autohide-delay"), .double(1000))
        XCTAssertEqual(store.get("com.apple.finder", "CreateDesktop"), .bool(false))
        XCTAssertEqual(snapshot.hidden, Set(MacElement.allCases))
        snapshot.restoreAll(store: store)
        XCTAssertEqual(store.values, initial()) // absent keys deleted again, not left behind
        XCTAssertTrue(snapshot.hidden.isEmpty); XCTAssertTrue(snapshot.saved.isEmpty)
    }
    func testHidingTwiceKeepsTheOriginal() {
        let store = MemoryStore(initial()); var snapshot = MacChromeSnapshot()
        snapshot.hide(.dock, store: store); snapshot.hide(.dock, store: store)
        snapshot.restore(.dock, store: store)
        XCTAssertEqual(store.values, initial())
    }
    func testRestoringOneElementLeavesSharedDomainElementHidden() {
        let store = MemoryStore(initial()); var snapshot = MacChromeSnapshot()
        snapshot.hide(.desktop, store: store); snapshot.hide(.stageManager, store: store)
        snapshot.restore(.stageManager, store: store)
        XCTAssertEqual(store.get("com.apple.WindowManager", "GloballyEnabled"), .bool(false))
        XCTAssertEqual(store.get("com.apple.WindowManager", "StandardHideWidgets"), .bool(true)) // desktop still hidden
        XCTAssertEqual(snapshot.hidden, [.desktop])
    }
    func testSnapshotSurvivesJSONRoundTrip() throws {
        let store = MemoryStore(initial()); var snapshot = MacChromeSnapshot()
        snapshot.hide(.dock, store: store); snapshot.hide(.desktop, store: store)
        var decoded = try JSONDecoder().decode(MacChromeSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        decoded.restoreAll(store: store) // a relaunched app can still restore
        XCTAssertEqual(store.values, initial())
    }
    func testRestoreWithoutHideChangesNothing() {
        let store = MemoryStore(initial()); var snapshot = MacChromeSnapshot()
        snapshot.restore(.dock, store: store); snapshot.restoreAll(store: store)
        XCTAssertEqual(store.values, initial())
    }
}
