import XCTest
@testable import MnomeSupport

final class FocusGateTests: XCTestCase {
    typealias F = FocusGate.Facts
    func testThePersonsChoiceIsFollowed() {
        XCTAssertEqual(FocusGate.verdict(F(before: .shown)), .follow) // Dock or Cmd+Tab from a visible window
        XCTAssertEqual(FocusGate.verdict(F(before: .nothing)), .follow) // from an empty workspace
    }
    func testMacOSsOwnPickIsUndone() {
        XCTAssertEqual(FocusGate.verdict(F(before: .gone)), .refuse) // the window before was closed, minimized, hidden or quit
        XCTAssertEqual(FocusGate.verdict(F(before: .shown, desktopClick: 0.1, finder: true)), .refuse)
        XCTAssertEqual(FocusGate.verdict(F(before: .shown, desktopClick: 2, finder: true)), .follow)
        XCTAssertEqual(FocusGate.verdict(F(before: .shown, desktopClick: 0.1)), .follow) // only Finder wakes from a desktop click
    }
    func testOurOwnDoingsAndStaleReportsAreIgnored() {
        XCTAssertEqual(FocusGate.verdict(F(before: .gone, ours: true)), .ignore)
        XCTAssertEqual(FocusGate.verdict(F(before: .shown, stillFocused: false)), .ignore)
    }
}
