import XCTest
@testable import MnomeSupport

final class HotCornerTests: XCTestCase {
    func testEnoughPushWithinASecondTriggersOncePerVisit() {
        var corner = HotCorner(corners: [.zero])
        XCTAssertFalse(corner.feed(at: .zero, delta: CGVector(dx: -40, dy: -20), time: 0))
        XCTAssertTrue(corner.feed(at: .zero, delta: CGVector(dx: -30, dy: -10), time: 0.5))
        XCTAssertFalse(corner.feed(at: .zero, delta: CGVector(dx: -200, dy: 0), time: 0.6), "once per visit")
        XCTAssertFalse(corner.feed(at: CGPoint(x: 40, y: 30), delta: CGVector(dx: 5, dy: 5), time: 0.7))
        XCTAssertTrue(corner.feed(at: CGPoint(x: 1, y: 0), delta: CGVector(dx: -120, dy: 0), time: 0.8), "armed again after leaving")
    }
    func testSlowPushesAndOutwardMovesDoNotCount() {
        var corner = HotCorner(corners: [.zero])
        XCTAssertFalse(corner.feed(at: .zero, delta: CGVector(dx: -60, dy: 0), time: 0))
        XCTAssertFalse(corner.feed(at: .zero, delta: CGVector(dx: -60, dy: 0), time: 1.5), "the first push is too old")
        XCTAssertFalse(corner.feed(at: .zero, delta: CGVector(dx: 80, dy: 80), time: 1.6), "moving away is no push")
        XCTAssertFalse(corner.feed(at: CGPoint(x: 0, y: 5), delta: CGVector(dx: -500, dy: 0), time: 1.7), "the left edge, not the corner")
    }
    func testCornersSkipThoseAnotherDisplayLiesBeyond() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900), right = CGRect(x: 1440, y: 0, width: 1920, height: 1080), below = CGRect(x: -300, y: 900, width: 800, height: 600), higher = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        XCTAssertEqual(HotCorner.corners(displays: [main, right]), [.zero], "the right display's corner leads back to the main one")
        XCTAssertEqual(HotCorner.corners(displays: [main, below]), [.zero, CGPoint(x: -300, y: 900)], "below and further left: nothing beyond it")
        XCTAssertEqual(HotCorner.corners(displays: [main, CGRect(x: 200, y: 900, width: 800, height: 600)]), [.zero], "below, its corner leads up into the main one")
        XCTAssertEqual(HotCorner.corners(displays: [main, higher]), [CGPoint(x: -1920, y: -300)])
    }
}
