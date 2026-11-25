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
    func testClockLooksLikeGnomeInEachLocale() {
        let date = Date(timeIntervalSince1970: 26_579_700) // 4 Nov 1970, 15:15 UTC
        func clock(_ id: String) -> String { StatusText.clock(date, locale: Locale(identifier: id), timeZone: TimeZone(secondsFromGMT: 0)!)}
        let emSpace = "\u{2003}"
        XCTAssertEqual(clock("en_US"), "Nov 4\(emSpace)3:15 PM")
        XCTAssertEqual(clock("en_GB"), "4 Nov\(emSpace)15:15")
        XCTAssertEqual(clock("de_DE"), "4. Nov.\(emSpace)15:15")
        XCTAssertTrue(clock("ja_JP").hasSuffix("\(emSpace)15:15")); XCTAssertTrue(clock("ja_JP").contains("11月4日"))
        XCTAssertFalse(clock("en_US").contains("Wed"))
    }
    func testStatusIcons() {
        XCTAssertEqual(StatusIcons.battery(percent: 0, charging: false), "battery-level-0-symbolic")
        XCTAssertEqual(StatusIcons.battery(percent: 44, charging: false), "battery-level-40-symbolic")
        XCTAssertEqual(StatusIcons.battery(percent: 45, charging: true), "battery-level-50-charging-symbolic")
        XCTAssertEqual(StatusIcons.battery(percent: 97, charging: true), "battery-level-100-charged-symbolic")
        XCTAssertEqual(StatusIcons.battery(percent: 140, charging: false), "battery-level-100-symbolic")
        XCTAssertEqual(StatusIcons.network(available: false, wifi: true, rssi: -40), "network-offline-symbolic")
        XCTAssertEqual(StatusIcons.network(available: true, wifi: false, rssi: nil), "network-wired-symbolic")
        XCTAssertEqual(StatusIcons.network(available: true, wifi: true, rssi: nil), "network-wireless-signal-excellent-symbolic")
        XCTAssertEqual(StatusIcons.network(available: true, wifi: true, rssi: -70), "network-wireless-signal-ok-symbolic")
        XCTAssertEqual(StatusIcons.network(available: true, wifi: true, rssi: -95), "network-wireless-signal-none-symbolic")
        XCTAssertEqual(StatusIcons.volume(level: 0.5, muted: true), "audio-volume-muted-symbolic")
        XCTAssertEqual(StatusIcons.volume(level: 0, muted: false), "audio-volume-muted-symbolic")
        XCTAssertEqual(StatusIcons.volume(level: 0.2, muted: false), "audio-volume-low-symbolic")
        XCTAssertEqual(StatusIcons.volume(level: 0.5, muted: false), "audio-volume-medium-symbolic")
        XCTAssertEqual(StatusIcons.volume(level: 1, muted: false), "audio-volume-high-symbolic")
    }
    func testWorkspaceDots() {
        XCTAssertEqual(WorkspaceDots.dots(count: 3, current: 1, on: true), [false, true, false])
        XCTAssertEqual(WorkspaceDots.dots(count: 3, current: 1, on: false), [true])
        XCTAssertEqual(WorkspaceDots.dots(count: 1, current: 0, on: true), [true])
        XCTAssertEqual(WorkspaceDots.dots(count: 0, current: 0, on: true), [true])
        XCTAssertEqual(WorkspaceDots.dots(count: 2, current: 9, on: true), [false, true])
        XCTAssertEqual(WorkspaceDots.label(count: 3, current: 1, on: true), "Activities, workspace 2 of 3")
        XCTAssertEqual(WorkspaceDots.label(count: 3, current: 1, on: false), "Activities")
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
