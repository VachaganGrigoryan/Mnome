import XCTest
@testable import MnomeSupport
final class TopBarTests: XCTestCase {
    func testNegativeDisplayCoordinates() {
        XCTAssertEqual(TopBarGeometry.frame(screen: CGRect(x: -1920, y: -200, width: 1920, height: 1080), visible: CGRect(x: -1920, y: -200, width: 1920, height: 1056), safeTop: 0), CGRect(x: -1920, y: 824, width: 1920, height: 32))
    }
    func testNotchAndMenuInsets() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(TopBarGeometry.frame(screen: screen, visible: screen, safeTop: 38).maxY, 944)
        XCTAssertEqual(TopBarGeometry.frame(screen: screen, visible: CGRect(x: 0, y: 0, width: 1512, height: 958), safeTop: 0).maxY, 958)
    }
    func testReplacingTheMenuBarTakesTheTopEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982), stale = CGRect(x: 0, y: 0, width: 1512, height: 948)
        XCTAssertEqual(TopBarGeometry.frame(screen: screen, visible: stale, safeTop: 32, replacesMenuBar: true), CGRect(x: 0, y: 950, width: 1512, height: 32))
        XCTAssertEqual(TopBarGeometry.frame(screen: screen, visible: stale, safeTop: 38, replacesMenuBar: true), CGRect(x: 0, y: 944, width: 1512, height: 38))
        let bar = TopBarGeometry.frame(screen: screen, visible: stale, safeTop: 0, replacesMenuBar: true)
        XCTAssertEqual(WorkArea.rect(visible: stale, bar: bar, dock: nil, screenTop: 982).maxY, 950)
        XCTAssertEqual(WorkArea.rect(visible: stale, bar: bar.offsetBy(dx: 0, dy: -32), dock: nil, screenTop: 982).maxY, 918)
    }
    func testBatteryAndMissingData() {
        XCTAssertNil(StatusText.battery(current: nil, maximum: nil, charging: false))
        XCTAssertNil(StatusText.battery(current: 1, maximum: 0, charging: false))
        XCTAssertEqual(StatusText.battery(current: 50, maximum: 100, charging: true), "Charging · 50%")
        XCTAssertEqual(StatusText.battery(current: 110, maximum: 100, charging: false), "100%")
    }
    func testNetwork() {
        XCTAssertEqual(StatusText.network(available: true, kind: "Wi-Fi"), "Wi-Fi connected")
        XCTAssertEqual(StatusText.network(available: false, kind: "Wi-Fi"), "No network connection")
    }
    func testClockUsesGivenLocaleAndZone() {
        let result = StatusText.clock(Date(timeIntervalSince1970: 0), locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(result.contains("Jan")); XCTAssertTrue(result.contains("12:00"))
    }
}
final class QuickSettingsSupportTests: XCTestCase {
    func testBatterySymbolBuckets() {
        XCTAssertEqual(StatusText.batterySymbol(percent: 0, charging: false), "battery.0")
        XCTAssertEqual(StatusText.batterySymbol(percent: 12, charging: false), "battery.25")
        XCTAssertEqual(StatusText.batterySymbol(percent: 13, charging: false), "battery.25")
        XCTAssertEqual(StatusText.batterySymbol(percent: 62, charging: false), "battery.75")
        XCTAssertEqual(StatusText.batterySymbol(percent: 100, charging: false), "battery.100")
        XCTAssertEqual(StatusText.batterySymbol(percent: 40, charging: true), "battery.100.bolt")
    }
    func testBatteryPercentParsing() {
        XCTAssertEqual(StatusText.batteryPercent(current: 50, maximum: 100), 50)
        XCTAssertNil(StatusText.batteryPercent(current: nil, maximum: 100))
    }
    func testShortcutChoices() {
        XCTAssertEqual(ShortcutChoice.all.count, 3)
        XCTAssertEqual(Set(ShortcutChoice.all.map(\.title)).count, 3)
        XCTAssertEqual(ShortcutChoice.choice(forMask: 0), ShortcutChoice.all[0])
        XCTAssertEqual(ShortcutChoice.choice(forMask: -5), ShortcutChoice.all[0])
        XCTAssertEqual(ShortcutChoice.choice(forMask: ShortcutChoice.all[2].mask), ShortcutChoice.all[2])
    }
}
