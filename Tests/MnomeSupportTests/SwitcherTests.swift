import XCTest
@testable import MnomeSupport

final class SwitcherTests: XCTestCase {
    /// Windows as (id, app, workspace, minimized); the list is in the order last used.
    private func state(_ windows: [(Int, String, Int, Bool)], current: Int = 1) throws -> WMState {
        let list = windows.map { #"{"id":\#($0.0),"app":"\#($0.1)","display":7,"workspace":\#($0.2),"minimized":\#($0.3),"hidden":false,"fullscreen":false,"sticky":false,"rect":{"x":0,"y":0,"w":1,"h":1}}"# }
        return try WMState(json: JSONSerialization.jsonObject(with: Data(#"{"windows":[\#(list.joined(separator: ","))],"workspaces":[1,2,3],"current":\#(current),"focus":null,"main":7,"mru":[\#(windows.map { "\($0.0)" }.joined(separator: ","))],"workspaces_on":true}"#.utf8)))
    }
    func testAppsInOrderLastUsedWithTheirWindowsAndTheSecondSelected() throws {
        var s = Switcher(state: try state([(1, "a", 1, false), (2, "b", 2, false), (3, "a", 2, false), (4, "c", 1, true)]), currentOnly: false)
        XCTAssertEqual(s.apps, [.init(app: "a", windows: [1, 3]), .init(app: "b", windows: [2]), .init(app: "c", windows: [4])]) // minimized-only apps last
        XCTAssertEqual(s.choice, 2)
        s.next(backwards: false); XCTAssertEqual(s.choice, 4)
        s.next(backwards: false); XCTAssertEqual(s.choice, 1)
        s.next(backwards: true); XCTAssertEqual(s.choice, 4)
        XCTAssertEqual(Switcher(state: try state([(1, "a", 1, false), (2, "b", 1, false)]), currentOnly: false, backwards: true).choice, 2)
    }
    func testWindowsOfOneApp() throws {
        var s = Switcher(state: try state([(1, "a", 1, false), (3, "a", 2, false), (5, "a", 1, false), (2, "b", 1, false)]), currentOnly: false, windowsOfFront: true)
        XCTAssertEqual(s.choice, 3)
        s.next(backwards: false); XCTAssertEqual(s.choice, 5)
        s.next(backwards: false); XCTAssertEqual(s.choice, 1)
        s.leaveWindows(); s.next(backwards: false); XCTAssertEqual(s.choice, 2)
        s.showWindows(); XCTAssertEqual(s.choice, 2)
    }
    func testCurrentWorkspaceOnly() throws {
        let s = Switcher(state: try state([(1, "a", 1, false), (2, "b", 2, false), (3, "c", 2, true), (4, "d", 1, true)]), currentOnly: true)
        XCTAssertEqual(s.apps.map(\.app), ["a", "d"])
        XCTAssertTrue(Switcher(state: try state([]), currentOnly: false).isEmpty)
        XCTAssertNil(Switcher(state: try state([]), currentOnly: false).choice)
    }
}
