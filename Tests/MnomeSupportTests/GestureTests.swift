import XCTest
@testable import MnomeSupport

final class SwipeTrackerTests: XCTestCase {
    private func swipe(_ points: [(Int, CGFloat, CGFloat)]) -> [SwipeTracker.Output] {
        var tracker = SwipeTracker()
        return points.enumerated().compactMap { i, p in tracker.feed(count: p.0, centroid: CGPoint(x: p.1, y: p.2), time: Double(i) * 0.01) }
    }
    func testLocksTheAxisThenFollowsTheFingers() {
        let out = swipe([(3, 0.5, 0.5), (3, 0.505, 0.5), (3, 0.53, 0.51), (3, 0.62, 0.5), (2, 0.62, 0.5)])
        XCTAssertEqual(out.first, .began(.horizontal))
        XCTAssertEqual(out[1], .update(0.4), "0.12 of the pad is 0.4 of a swipe")
        guard case let .ended(progress, velocity) = out.last else { return XCTFail("\(out)") }
        XCTAssertEqual(progress, 0.4, accuracy: 0.001); XCTAssertGreaterThan(velocity, 0)
    }
    func testUpIsPositiveAndTinyMovesStartNothing() {
        XCTAssertEqual(swipe([(3, 0.5, 0.5), (3, 0.51, 0.505), (0, 0.5, 0.5)]), [], "under the lock distance")
        let up = swipe([(3, 0.5, 0.2), (3, 0.5, 0.25), (3, 0.5, 0.5)])
        XCTAssertEqual(up, [.began(.vertical), .update(1)])
    }
    func testAFourthFingerCancels() {
        XCTAssertEqual(swipe([(3, 0.5, 0.5), (3, 0.6, 0.5), (4, 0.6, 0.5)]).last, .cancelled)
        XCTAssertEqual(swipe([(2, 0.5, 0.5), (2, 0.9, 0.5)]), [], "two fingers are the apps' own scrolling")
    }
    func testCommitsPastHalfWayOrOnAFlick() {
        XCTAssertTrue(SwipeTracker.commits(progress: -0.6, velocity: 0))
        XCTAssertFalse(SwipeTracker.commits(progress: 0.3, velocity: 0.2))
        XCTAssertTrue(SwipeTracker.commits(progress: 0.2, velocity: 2), "a flick")
        XCTAssertFalse(SwipeTracker.commits(progress: 0.2, velocity: -2), "flicked back")
    }
}
