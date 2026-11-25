import XCTest
@testable import MnomeSupport
final class MenuSupportTests: XCTestCase {
    private func calendar(_ id: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.locale = Locale(identifier: id); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ c: Calendar) -> Date { c.date(from: DateComponents(year: y, month: m, day: d))! }
    func testNovember2026LooksLikeTheGnomeReference() {
        let c = calendar("en_US"), grid = MonthGrid(month: date(2026, 11, 4, c), today: date(2026, 11, 4, c), calendar: c)
        XCTAssertEqual(grid.days.count, 42)
        XCTAssertEqual(grid.weekdays, ["S", "M", "T", "W", "T", "F", "S"])
        XCTAssertEqual(grid.days.first?.number, "25"); XCTAssertEqual(grid.days.last?.number, "05") // a whole October week first, as GNOME
        XCTAssertEqual(grid.days.filter(\.inMonth).count, 30)
        XCTAssertEqual(grid.days.firstIndex(where: \.today), 10)
        XCTAssertTrue(grid.days[7].weekend); XCTAssertFalse(grid.days[8].weekend)
        XCTAssertEqual(grid.title, "November")
    }
    func testWeekStartAndYearFollowTheLocale() {
        let c = calendar("en_GB"), grid = MonthGrid(month: date(2027, 3, 1, c), today: date(2026, 11, 4, c), calendar: c)
        XCTAssertEqual(grid.weekdays.first, "M")
        XCTAssertEqual(grid.days[7].number, "01") // 1 March 2027 is a Monday: a week of February first
        XCTAssertEqual(grid.title, "March 2027")
        XCTAssertNil(grid.days.firstIndex(where: \.today))
    }
    func testAppMenusKeepTheMacPositionsAndStopBeforeTheClock() {
        let items: [(x: CGFloat, width: CGFloat)] = [(43, 77), (120, 50), (170, 45), (215, 69)]
        XCTAssertEqual(AppMenuStrip.layout(items, start: 43, end: 600), 0..<4) // Activities fits the Apple slot: all, where the Mac has them
        XCTAssertEqual(AppMenuStrip.layout(items, start: 100, end: 600), 1..<4) // a wider left side covers the app's name: never moved, left out
        XCTAssertEqual(AppMenuStrip.layout(items, start: 43, end: 260), 0..<3) // the last would reach the clock
        XCTAssertEqual(AppMenuStrip.layout(items, start: 400, end: 600), 0..<0)
        XCTAssertEqual(AppMenuStrip.layout([], start: 40, end: 600), 0..<0)
    }
    func testRunCommand() {
        XCTAssertEqual(RunCommand("  "), .nothing)
        XCTAssertEqual(RunCommand("r"), .restartShell)
        XCTAssertEqual(RunCommand(" open -a Safari "), .command("open -a Safari"))
        XCTAssertEqual(RunCommand.remember("b", in: ["a", "b", "c"]), ["b", "a", "c"])
        XCTAssertEqual(RunCommand.remember(" ", in: ["a"]), ["a"])
        XCTAssertEqual(RunCommand.remember("z", in: ["a", "b"], limit: 2), ["z", "a"])
    }
    func testMediaKeys() {
        XCTAssertEqual(MediaKey.parse(subtype: 8, data1: 0x0000_0A00)?.key, .volumeUp)
        XCTAssertEqual(MediaKey.parse(subtype: 8, data1: 0x0001_0A00)?.down, true)
        XCTAssertEqual(MediaKey.parse(subtype: 8, data1: 0x0007_0B00)?.down, false)
        XCTAssertEqual(MediaKey.parse(subtype: 8, data1: 0x0003_0A00)?.key, .brightnessDown)
        XCTAssertNil(MediaKey.parse(subtype: 8, data1: 0x0010_0A00)) // play/pause: the Mac's
        XCTAssertNil(MediaKey.parse(subtype: 7, data1: 0x0000_0A00))
        XCTAssertEqual(MediaKey.step(0.5, up: true), 9.0 / 16)
        XCTAssertEqual(MediaKey.step(0.51, up: false), 7.0 / 16)
        XCTAssertEqual(MediaKey.step(1, up: true), 1); XCTAssertEqual(MediaKey.step(0.01, up: false), 0)
    }
    func testSessionActions() {
        XCTAssertEqual(SessionAction.allCases.map(\.menuTitle), ["Suspend", "Restart…", "Power Off…", "Log Out…"])
        XCTAssertFalse(SessionAction.suspend.asks); XCTAssertTrue(SessionAction.powerOff.asks)
        XCTAssertEqual(SessionAction.restart.message(seconds: 60), "The system will restart automatically in 60 seconds.")
        XCTAssertEqual(SessionAction.logOut.message(seconds: 1), "You will be logged out automatically in 1 second.")
    }
}
