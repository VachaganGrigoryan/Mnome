import XCTest
@testable import MnomeSupport

final class ParkingTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    func testCornerAvoidsNeighbouringDisplays() {
        let right = CGRect(x: 1512, y: -98, width: 1920, height: 1080), left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(Parking.corner(displays: [main], main: main), .bottomLeft)
        XCTAssertEqual(Parking.corner(displays: [main, right], main: main), .bottomLeft)
        XCTAssertEqual(Parking.corner(displays: [main, left], main: main), .bottomRight)
        XCTAssertNil(Parking.corner(displays: [main, left, right], main: main))
        XCTAssertEqual(Parking.corner(displays: [main, CGRect(x: -200, y: -1080, width: 1920, height: 1080)], main: main), .bottomLeft) // above
        XCTAssertEqual(Parking.corner(displays: [main, CGRect(x: -1920, y: -900, width: 1920, height: 1080)], main: main), .bottomLeft) // left, but higher
        XCTAssertEqual(Parking.corner(displays: [main, CGRect(x: -800, y: 982, width: 1920, height: 1080)], main: main), .bottomRight) // below left
    }
    func testParkedFramesFromTheSpikeAreRecognised() {
        let displays = [main, CGRect(x: 1512, y: -98, width: 1920, height: 1080)]
        XCTAssertEqual(Parking.origin(size: CGSize(width: 420, height: 312), corner: .bottomLeft, main: main), CGPoint(x: -419, y: 981))
        XCTAssertEqual(Parking.origin(size: CGSize(width: 420, height: 312), corner: .bottomRight, main: main), CGPoint(x: 1511, y: 981))
        XCTAssertTrue(Parking.isParked(CGRect(x: -1511, y: 941, width: 1512, height: 948), displays: displays))
        XCTAssertTrue(Parking.isParked(CGRect(x: -419, y: 950, width: 420, height: 312), displays: displays))
        XCTAssertFalse(Parking.isParked(CGRect(x: 556, y: 346, width: 420, height: 312), displays: displays))
        XCTAssertFalse(Parking.isParked(CGRect(x: -300, y: 900, width: 420, height: 312), displays: displays))
    }
    func testWorkAreaSitsBetweenBarAndDock() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 948)
        XCTAssertEqual(WorkArea.rect(visible: visible, bar: CGRect(x: 0, y: 916, width: 1512, height: 32), dock: CGRect(x: 400, y: 8, width: 700, height: 80)), CGRect(x: 0, y: 88, width: 1512, height: 828))
        XCTAssertEqual(WorkArea.rect(visible: visible, bar: nil, dock: nil), visible)
        let r = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(WorkArea.flip(r, primaryHeight: 982), CGRect(x: 10, y: 922, width: 30, height: 40))
        XCTAssertEqual(WorkArea.flip(WorkArea.flip(r, primaryHeight: 982), primaryHeight: 982), r)
    }
}
final class RecoveryTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982), parked = CGRect(x: -399, y: 950, width: 400, height: 300), original = CGRect(x: 100.5, y: 120, width: 400, height: 300)
    func record(pid: Int32 = 7, started: Double = 1000, window: UInt64 = 42) -> ParkedRecord { ParkedRecord(pid: pid, started: started, bundle: "a.b", window: window, original: original, parked: parked) }
    func live(pid: Int32 = 7, started: Double = 1000, window: UInt64 = 42, bundle: String = "a.b", frame: CGRect? = nil) -> LiveWindow { LiveWindow(pid: pid, started: started, bundle: bundle, window: window, frame: frame ?? parked) }
    func steps(_ records: [ParkedRecord], _ windows: [LiveWindow], running: [Int32: Double] = [7: 1000]) -> [RecoveryStep] { Recovery.steps(records: records, live: windows, running: running, displays: [main], main: main) }
    func testExactIdentityRestoresTheExactFrame() { XCTAssertEqual(steps([record()], [live()]), [.restore(record(), live(), original)]) }
    func testReusedProcessIdIsNotMistaken() {
        let other = live(started: 5000, bundle: "x.y")
        XCTAssertEqual(steps([record()], [other], running: [7: 5000]), [.drop(record())]) // another app's window is never touched
    }
    func testRestartedAppsParkedWindowIsCentred() {
        let again = live(pid: 9, started: 5000, window: 77)
        XCTAssertEqual(steps([record()], [again], running: [:]), [.drop(record()), .center(again, CGRect(x: 556, y: 341, width: 400, height: 300))])
        let elsewhere = live(pid: 9, started: 5000, window: 78, frame: CGRect(x: -699, y: 900, width: 700, height: 500)) // parked by something else
        XCTAssertEqual(steps([record()], [elsewhere], running: [:]), [.drop(record())])
        XCTAssertEqual(steps([record()], [live(), live(window: 43)]), [.restore(record(), live(), original)]) // another window of a running app is not ours
    }
    func testVisibleWindowsAreLeftAlone() {
        let seen = live(frame: CGRect(x: 300, y: 300, width: 400, height: 300))
        XCTAssertEqual(steps([record()], [seen]), [.drop(record())])
    }
    func testAStripIsNotInSightSoItIsStillBroughtBack() {
        let strip = live(frame: CGRect(x: -390, y: 300, width: 400, height: 300)) // 10 points showing: moved by macOS, not rescued
        XCTAssertEqual(steps([record()], [strip]), [.restore(record(), strip, original)])
        XCTAssertTrue(Recovery.inSight(CGRect(x: -360, y: 300, width: 400, height: 300), displays: [main]))
        XCTAssertFalse(Recovery.inSight(CGRect(x: 0, y: 970, width: 400, height: 300), displays: [main]))
    }
    func testMissingWindowOfARunningAppIsKept() { XCTAssertEqual(steps([record()], []), [.keep(record())]) } // hung, or on another native Space
    func testEndedAppsRecordIsDropped() { XCTAssertEqual(steps([record()], [], running: [:]), [.drop(record())]) }
    func testJournalHasOneOwnerAndTheNextSeesItsWrites() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("parked.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = RecoveryJournal(url: url), second = RecoveryJournal(url: url)
        XCTAssertTrue(first.acquire()); XCTAssertTrue(first.acquire()); XCTAssertFalse(second.acquire())
        try first.put(record()); first.release()
        XCTAssertTrue(second.acquire()); XCTAssertEqual(second.records, [record()])
    }
    func testMissingDisplayBringsTheWindowToTheMainOne() {
        let far = ParkedRecord(pid: 7, started: 1000, bundle: "a.b", window: 42, original: CGRect(x: 4000, y: 100, width: 400, height: 300), parked: parked)
        XCTAssertEqual(steps([far], [live()]), [.restore(far, live(), CGRect(x: 556, y: 341, width: 400, height: 300))])
    }
    func testJournalSurvivesRestartAndSetsAsideAHalfWrittenFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("parked.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = RecoveryJournal(url: url)
        var pending = record(); pending.parked = nil
        try journal.put(pending); try journal.put(record()); try journal.put(record(window: 43))
        XCTAssertEqual(RecoveryJournal(url: url).records, [record(), record(window: 43)]) // confirmed replaces pending
        try journal.remove(record())
        XCTAssertEqual(RecoveryJournal(url: url).records, [record(window: 43)])
        try Data("[{\"pid\":7,".utf8).write(to: url)
        XCTAssertTrue(RecoveryJournal(url: url).records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".unreadable"))
    }
    func testJournalThatCannotBeWrittenThrowsAndKeepsItsRecords() {
        let journal = RecoveryJournal(url: URL(fileURLWithPath: "/dev/null/parked.json"))
        XCTAssertThrowsError(try journal.put(record())); XCTAssertTrue(journal.records.isEmpty)
    }
}
final class IntentLedgerTests: XCTestCase {
    let frame = CGRect(x: 10, y: 10, width: 100, height: 100), now = Date(timeIntervalSince1970: 100)
    func testLateResultsAreDropped() {
        var ledger = IntentLedger(); ledger.intend(1, .shown(frame), revision: 1); ledger.intend(1, .parked, revision: 2)
        XCTAssertEqual(ledger.finished(1, revision: 1, ok: true, observed: frame), .stale)
        XCTAssertEqual(ledger.target(1), .parked)
        XCTAssertEqual(ledger.finished(9, revision: 1, ok: true, observed: frame), .stale)
    }
    func testFailuresRetryThenGiveUpAndANewIntentStartsOver() {
        var ledger = IntentLedger(); ledger.intend(1, .parked, revision: 1)
        XCTAssertEqual(ledger.finished(1, revision: 1, ok: false, observed: nil), .retry)
        XCTAssertEqual(ledger.finished(1, revision: 1, ok: false, observed: nil), .retry)
        XCTAssertEqual(ledger.finished(1, revision: 1, ok: false, observed: frame), .gaveUp)
        ledger.intend(1, .shown(frame), revision: 2)
        XCTAssertEqual(ledger.finished(1, revision: 2, ok: true, observed: frame), .done)
    }
    func testLateFocusDoesNotBringBackWhatWeJustPutAway() {
        for target in [IntentLedger.Target.parked, .minimized] {
            var ledger = IntentLedger(); XCTAssertFalse(ledger.isPuttingAway(1, now: now))
            ledger.intend(1, target, revision: 1); XCTAssertTrue(ledger.isPuttingAway(1, now: now)) // on its way out
            _ = ledger.finished(1, revision: 1, ok: true, observed: nil, now: now)
            XCTAssertTrue(ledger.isPuttingAway(1, now: now.addingTimeInterval(0.4)))
            XCTAssertFalse(ledger.isPuttingAway(1, now: now.addingTimeInterval(0.6))) // the person chose it, in the Dock or with Cmd+Tab
            ledger.intend(1, .shown(frame), revision: 2); XCTAssertFalse(ledger.isPuttingAway(1, now: now))
        }
    }
    func testOwnMovesAreEchoesAndThePersonsAreNot() {
        var ledger = IntentLedger(); let other = frame.offsetBy(dx: 50, dy: 0)
        XCTAssertFalse(ledger.isEcho(1, frame: frame, now: now))
        ledger.intend(1, .shown(frame), revision: 1)
        XCTAssertTrue(ledger.isEcho(1, frame: other, now: now)) // still moving
        _ = ledger.finished(1, revision: 1, ok: true, observed: frame, now: now)
        XCTAssertTrue(ledger.isEcho(1, frame: other, now: now.addingTimeInterval(0.4)))
        XCTAssertFalse(ledger.isEcho(1, frame: other, now: now.addingTimeInterval(0.6)))
        XCTAssertTrue(ledger.isEcho(1, frame: frame.offsetBy(dx: 0.5, dy: 0), now: now.addingTimeInterval(9)))
    }
}
final class WindowProtocolTests: XCTestCase {
    func testOpsDecodeAndUnknownOnesAreRefused() {
        XCTAssertEqual(WMOp(json: ["op": "place", "window": NSNumber(value: UInt64(1) << 40), "rect": ["x": 1, "y": 2, "w": 3, "h": 4]]), .place(1 << 40, WMRect(x: 1, y: 2, w: 3, h: 4)))
        XCTAssertEqual(WMOp(json: ["op": "park", "window": 5]), .park(5))
        XCTAssertNil(WMOp(json: ["op": "place", "window": 5])); XCTAssertNil(WMOp(json: ["op": "explode", "window": 5]))
    }
    func testFractionalFramesRoundToWholePoints() { XCTAssertEqual(WMRect(CGRect(x: 100.5, y: 0.4, width: 400.2, height: 299.6)), WMRect(x: 101, y: 0, w: 400, h: 300)) }
}
