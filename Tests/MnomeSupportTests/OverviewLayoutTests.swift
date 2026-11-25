import XCTest
@testable import MnomeSupport
final class OverviewLayoutTests: XCTestCase {
    let area = CGRect(x: 0, y: 0, width: 900, height: 540)
    func testTheBoxKeepsTheWorkAreaShape() {
        let box = OverviewLayout.box(workArea: CGSize(width: 1280, height: 768), in: CGRect(x: 0, y: 108, width: 1280, height: 553))
        XCTAssertEqual(box.height, 553, accuracy: 0.5); XCTAssertEqual(box.width, 921.7, accuracy: 0.5); XCTAssertEqual(box.midX, 640, accuracy: 0.5) // GNOME's 922x553
    }
    func testOneWindowIsCentredAndNotEnlargedPastGnomesCap() {
        let slot = OverviewLayout.slots([(1, CGRect(x: 275, y: 153, width: 730, height: 526))], in: CGRect(x: 0, y: 0, width: 922, height: 553), screenHeight: 800)[1]!
        XCTAssertEqual(slot.width, 730 * 0.95, accuracy: 0.5); XCTAssertEqual(slot.midX, 461, accuracy: 0.5); XCTAssertEqual(slot.midY, 276.5, accuracy: 0.5)
    }
    func testTwoWindowsStaySideBySideInOrder() {
        let s = OverviewLayout.slots([(1, CGRect(x: 600, y: 100, width: 500, height: 400)), (2, CGRect(x: 0, y: 100, width: 500, height: 400))], in: area, screenHeight: 800)
        XCTAssertEqual(s[2]!.midY, s[1]!.midY, accuracy: 0.5); XCTAssertLessThan(s[2]!.maxX, s[1]!.minX)
    }
    func testManyWindowsUseRowsAndNeverOverlapOrLeave() {
        let windows = (0..<9).map { (UInt64($0), CGRect(x: CGFloat($0 % 3) * 400, y: CGFloat($0 / 3) * 250, width: 600, height: 400)) }
        let s = OverviewLayout.slots(windows, in: area, screenHeight: 800)
        XCTAssertEqual(s.count, 9)
        XCTAssertGreaterThan(Set(s.values.map { Int($0.midY) }).count, 1)
        for (a, r) in s { XCTAssertTrue(area.insetBy(dx: -0.5, dy: -0.5).contains(r), "\(a) \(r)"); for (b, q) in s where a < b { XCTAssertFalse(r.insetBy(dx: 1, dy: 1).intersects(q), "\(a) \(b)") } }
    }
    func testNothingToPlace() { XCTAssertTrue(OverviewLayout.slots([], in: area, screenHeight: 800).isEmpty); XCTAssertTrue(OverviewLayout.slots([(1, .zero)], in: area, screenHeight: 800).isEmpty) }
    func testCalculator() {
        XCTAssertEqual(Calculator.evaluate("2+3*4"), 14); XCTAssertEqual(Calculator.evaluate("(2+3)*4"), 20); XCTAssertEqual(Calculator.evaluate("2^3^2"), 512)
        XCTAssertEqual(Calculator.evaluate("-3 + 10 % 4"), -1); XCTAssertEqual(Calculator.evaluate("1,5×2"), 3)
        XCTAssertNil(Calculator.evaluate("42")); XCTAssertNil(Calculator.evaluate("set")); XCTAssertNil(Calculator.evaluate("2+")); XCTAssertNil(Calculator.evaluate("1/0")); XCTAssertNil(Calculator.evaluate("(1+2"))
        XCTAssertEqual(Calculator.format(14), "14"); XCTAssertEqual(Calculator.format(1.0 / 3), "0.3333333333")
    }
}
final class SettingsSearchTests: XCTestCase {
    func testNamesFirstThenKeywords() {
        XCTAssertEqual(SettingsPane.search("blue").first?.name, "Bluetooth")
        XCTAssertEqual(SettingsPane.search("dark").map(\.name), ["Appearance"])
        XCTAssertEqual(SettingsPane.search("key").first?.name, "Keyboard")
        XCTAssertTrue(SettingsPane.search("screen rec").contains { $0.name == "Privacy & Security" })
        XCTAssertTrue(SettingsPane.search("  ").isEmpty); XCTAssertTrue(SettingsPane.search("zzzz").isEmpty)
    }
}
