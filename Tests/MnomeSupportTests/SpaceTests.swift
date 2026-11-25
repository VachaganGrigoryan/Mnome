import XCTest
@testable import MnomeSupport

final class MacSpacesTests: XCTestCase {
    func testOnlyDisplaysWithSeveralDesktopsCount() {
        let listed: [[String: Any]] = [
            ["Display Identifier": "Main", "Spaces": [["type": 0, "ManagedSpaceID": 1], ["type": 4, "ManagedSpaceID": 9]]], // one desktop, one full-screen app
            ["Display Identifier": "Dell", "Spaces": [["type": 0], ["type": 0], ["type": 0]]],
        ]
        XCTAssertEqual(MacSpaces.extra(from: listed), ["Dell": 3])
        XCTAssertEqual(MacSpaces.extra(from: []), [:])
    }
}
