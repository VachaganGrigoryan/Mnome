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
        XCTAssertEqual(WMEvent.dragAway(4, x: 10, y: 20, header: 12).json as NSDictionary, ["type": "drag_away", "id": 4, "x": 10, "y": 20, "header": 12])
        let column = WMBorder(workspace: 1, display: 7, column: nil, boundary: 1), row = WMBorder(workspace: 1, display: 7, column: 0, boundary: 2)
        XCTAssertEqual(WMEvent.dragBorder(column, coordinate: 500).json as NSDictionary, ["type": "drag_border", "key": ["workspace": 1, "display": 7], "border": ["column": ["boundary": 1]], "coordinate": 500])
        XCTAssertEqual((WMEvent.dragBorder(row, coordinate: 300).json["border"] as? NSDictionary), ["row": ["column": 0, "boundary": 2]])
    }
    func testHitsReadTheCoresAnswer() {
        let hit = WMHit(json: ["snap": "top_left", "border": ["key": ["workspace": 1, "display": 7], "border": ["column": ["boundary": 1]]]])
        XCTAssertEqual(hit.snap, .topLeft); XCTAssertEqual(hit.border, WMBorder(workspace: 1, display: 7, column: nil, boundary: 1)); XCTAssertTrue(hit.border!.vertical)
        let row = WMHit(json: ["snap": NSNull(), "border": ["key": ["workspace": 1, "display": 7], "border": ["row": ["column": 1, "boundary": 1]]]])
        XCTAssertNil(row.snap); XCTAssertEqual(row.border?.column, 1); XCTAssertFalse(row.border!.vertical)
        XCTAssertNil(WMHit(json: ["snap": NSNull(), "border": NSNull()]).border)
    }
    func testPlacementDecodesEachForm() throws {
        func placement(_ value: Any) throws -> WMPlacement? {
            let window: [String: Any] = ["id": 1, "app": "a", "display": 1, "workspace": 1, "minimized": false, "hidden": false, "fullscreen": false, "sticky": false, "rect": ["x": 0, "y": 0, "w": 1, "h": 1], "placement": value]
            return try WMState(json: ["windows": [window], "workspaces": [1], "current": 1, "main": 1, "mru": [], "workspaces_on": true]).windows[0].placement
        }
        XCTAssertEqual(try placement("free"), .free); XCTAssertEqual(try placement("maximized"), .maximized); XCTAssertEqual(try placement(["tiled": ["cell": 0]]), .tiled)
    }
    func testTilePreviewMatchesTheCoresHalvesAndQuarters() {
        let work = WMRect(x: 0, y: 32, w: 1281, h: 769)
        XCTAssertEqual(TilePreview.rect(for: .left, work: work), WMRect(x: 0, y: 32, w: 640, h: 769))
        XCTAssertEqual(TilePreview.rect(for: .right, work: work), WMRect(x: 640, y: 32, w: 641, h: 769))
        XCTAssertEqual(TilePreview.rect(for: .bottomRight, work: work), WMRect(x: 640, y: 416, w: 641, h: 385))
        XCTAssertEqual(TilePreview.rect(for: .topLeft, work: work), WMRect(x: 0, y: 32, w: 640, h: 384))
        XCTAssertEqual(TilePreview.rect(for: .maximize, work: work), work)
    }
}
