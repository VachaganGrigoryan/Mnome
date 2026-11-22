import XCTest
@testable import MnomeSupport

final class WorkspaceStateTests: XCTestCase {
    private func state(on: Bool = true, _ windows: String) throws -> WMState {
        try WMState(json: JSONSerialization.jsonObject(with: Data("""
        {"windows":[\(windows)],"workspaces":[1,2],"current":1,"focus":null,"main":7,"mru":[2,1],"workspaces_on":\(on),"schema":2}
        """.utf8)))
    }
    private func window(_ id: Int, workspace: Int = 2, display: Int = 7, minimized: Bool = false, hidden: Bool = false, fullscreen: Bool = false, sticky: Bool = false) -> String {
        """
        {"id":\(id),"app":"a","display":\(display),"workspace":\(workspace),"minimized":\(minimized),"hidden":\(hidden),"fullscreen":\(fullscreen),"sticky":\(sticky),"rect":{"x":0,"y":0,"w":1,"h":1}}
        """
    }
    func testOnlyOrdinaryWindowsOfOtherWorkspacesAreParked() throws {
        let s = try state([window(1), window(2, workspace: 1), window(3, display: 8), window(4, minimized: true), window(5, hidden: true), window(6, fullscreen: true), window(7, sticky: true)].joined(separator: ","))
        XCTAssertEqual(s.windows.map(\.id).filter(s.isParked), [1])
        XCTAssertEqual(s.windows.map(\.id).filter(s.isShown), [2, 3, 6, 7])
        XCTAssertFalse(s.isShown(99)); XCTAssertFalse(s.isParked(99))
        XCTAssertEqual(s.mru, [2, 1])
    }
    func testNothingIsParkedWhileWorkspacesAreOff() throws { let s = try state(on: false, window(1)); XCTAssertFalse(s.isParked(1)); XCTAssertTrue(s.isShown(1)) }
    func testNewEventsSpeakTheCoresLanguage() {
        XCTAssertEqual(WMEvent.hidden(4, true).json as NSDictionary, ["type": "hidden", "id": 4, "on": true])
        XCTAssertEqual(WMEvent.workspacesOn(false).json as NSDictionary, ["type": "workspaces_on", "on": false])
        XCTAssertEqual(WMEvent.carryWindow(4, -1).json as NSDictionary, ["type": "carry_window", "id": 4, "delta": -1])
        XCTAssertEqual(WMEvent.moved(4, WMRect(x: 0, y: 0, w: 1, h: 1), bySystem: true).json["by_system"] as? Bool, true)
        XCTAssertEqual(WMEvent.moved(4, WMRect(x: 0, y: 0, w: 1, h: 1)).json["by_system"] as? Bool, false)
    }
}
