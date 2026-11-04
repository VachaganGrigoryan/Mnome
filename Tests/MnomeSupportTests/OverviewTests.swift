import XCTest
@testable import MnomeSupport
final class OverviewTests: XCTestCase {
    func testContentSelection() {
        XCTAssertEqual(OverviewContent.content(query: "", windowsMode: true), .windows)
        XCTAssertEqual(OverviewContent.content(query: "   ", windowsMode: true), .windows)
        XCTAssertEqual(OverviewContent.content(query: "", windowsMode: false), .appGrid)
        XCTAssertEqual(OverviewContent.content(query: "saf", windowsMode: true), .searchResults)
        XCTAssertEqual(OverviewContent.content(query: " saf ", windowsMode: false), .searchResults)
    }
    func testEscapeClearsSearchBeforeClosing() {
        XCTAssertEqual(EscapeAction.escape(query: "saf"), .clearSearch)
        XCTAssertEqual(EscapeAction.escape(query: "  "), .clearSearch)
        XCTAssertEqual(EscapeAction.escape(query: ""), .close)
    }
    func testWindowMatchingIsCaseInsensitiveOnTitleAndApp() {
        XCTAssertTrue(OverviewContent.matches(query: "SAF", title: "Start Page", app: "Safari"))
        XCTAssertTrue(OverviewContent.matches(query: "start", title: "Start Page", app: "Safari"))
        XCTAssertFalse(OverviewContent.matches(query: "mail", title: "Start Page", app: "Safari"))
        XCTAssertFalse(OverviewContent.matches(query: " ", title: "Start Page", app: "Safari"))
    }
}
