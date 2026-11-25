import XCTest
@testable import MnomeSupport

final class SuperTapTests: XCTestCase {
    let right: UInt64 = 0x10_0010, left: UInt64 = 0x10_0008, shift: UInt64 = 0x2_0002
    func tap(_ steps: [(Int64, UInt64)], _ key: SuperKey = .rightCommand) -> [Bool] { var t = SuperTap(); return steps.map { t.flagsChanged(key: $0.0, flags: $0.1, superKey: key) } }
    func testLoneTapFiresOnRelease() { XCTAssertEqual(tap([(54, right), (54, 0)]), [false, true]) }
    func testLeftCommandNeverFires() { XCTAssertEqual(tap([(55, left), (55, 0)]), [false, false]) }
    func testShiftReleasedFirstDoesNotFire() { // gnome-mac's bug: Cmd+Shift+4, then Shift up, then Cmd up
        XCTAssertEqual(tap([(54, right), (56, right | shift), (56, right), (54, 0)]), [false, false, false, false])
        XCTAssertEqual(tap([(56, shift), (54, right | shift), (56, right), (54, 0)]), [false, false, false, false])
    }
    func testBothCommandsDoNotFire() { XCTAssertEqual(tap([(55, left), (54, right | left), (54, left), (55, 0)]), [false, false, false, false]) }
    func testKeyClickOrScrollCancels() {
        var router = KeyRouter()
        XCTAssertEqual(router.flagsChanged(key: 54, flags: right), .pass); router.pointer()
        XCTAssertEqual(router.flagsChanged(key: 54, flags: 0), .pass)
        _ = router.flagsChanged(key: 54, flags: right); XCTAssertEqual(router.keyDown(key: 8, flags: right, repeated: false), .pass); _ = router.keyUp(key: 8)
        XCTAssertEqual(router.flagsChanged(key: 54, flags: 0), .pass)
        _ = router.flagsChanged(key: 54, flags: right); XCTAssertEqual(router.flagsChanged(key: 54, flags: 0), .superTap)
    }
    func testRightOptionAsSuper() { XCTAssertEqual(tap([(61, 0x8_0040), (61, 0)], .rightOption), [false, true]); XCTAssertEqual(tap([(54, right), (54, 0)], .rightOption), [false, false]) }
}
final class KeyRouterTests: XCTestCase {
    let right: UInt64 = 0x10_0010, left: UInt64 = 0x10_0008, shift: UInt64 = 0x2_0002, option: UInt64 = 0x8_0020
    func testSuperChordRunsOnceAndIsHiddenFromApps() {
        var r = KeyRouter()
        XCTAssertEqual(r.keyDown(key: 123, flags: right | 0xA0_0000, repeated: false), .run(.tileLeft)) // arrows carry the fn and keypad flags
        XCTAssertEqual(r.keyDown(key: 123, flags: right | 0xA0_0000, repeated: true), .swallow)
        XCTAssertEqual(r.keyUp(key: 123), .swallow); XCTAssertEqual(r.keyUp(key: 123), .pass)
        XCTAssertEqual(r.keyDown(key: 123, flags: right | shift, repeated: false), .run(.moveLeft))
        XCTAssertEqual(r.keyDown(key: 53, flags: option, repeated: false), .run(.cycle))
        XCTAssertEqual(r.keyDown(key: 23, flags: right, repeated: false), .run(.launch5))
    }
    func testEverythingElseReachesTheApp() {
        var r = KeyRouter()
        XCTAssertEqual(r.keyDown(key: 123, flags: left, repeated: false), .pass)          // left Cmd+Left
        XCTAssertEqual(r.keyDown(key: 123, flags: left | right, repeated: false), .pass)  // both
        XCTAssertEqual(r.keyDown(key: 8, flags: right, repeated: false), .pass)           // right Cmd+C
        XCTAssertEqual(r.keyDown(key: 123, flags: option, repeated: false), .pass)        // Option+Left moves by word
        XCTAssertEqual(r.keyDown(key: 0, flags: 0, repeated: false), .pass)               // plain A
        XCTAssertEqual(r.keyUp(key: 8), .pass)
    }
    func testRepeatsStaySwallowedWhenSuperIsLetGoFirst() {
        var r = KeyRouter(); _ = r.keyDown(key: 123, flags: right, repeated: false)
        XCTAssertEqual(r.keyDown(key: 123, flags: 0, repeated: true), .swallow); XCTAssertEqual(r.keyUp(key: 123), .swallow)
        _ = r.keyDown(key: 123, flags: right, repeated: false); r.reset()
        XCTAssertEqual(r.keyUp(key: 123), .pass)
    }
    func testAKeyAnAppAlreadyHoldsStaysItsOwn() { // Left held in an app, then Super pressed while it repeats
        var r = KeyRouter()
        XCTAssertEqual(r.keyDown(key: 123, flags: 0, repeated: false), .pass)
        XCTAssertEqual(r.keyDown(key: 123, flags: right, repeated: true), .pass); XCTAssertEqual(r.keyUp(key: 123), .pass)
        r.recording = true // and the same when recording starts meanwhile
        XCTAssertEqual(r.keyDown(key: 8, flags: 0, repeated: true), .pass); XCTAssertEqual(r.keyUp(key: 8), .pass)
    }
    func testAnUnseenReleaseDoesNotSwallowTheNextOne() {
        var r = KeyRouter(); _ = r.keyDown(key: 123, flags: right, repeated: false) // release lost
        XCTAssertEqual(r.keyDown(key: 123, flags: 0, repeated: false), .pass); XCTAssertEqual(r.keyUp(key: 123), .pass)
    }
    func testRecordingTakesTheNextChordAndEscapeCancels() {
        var r = KeyRouter(); r.recording = true
        XCTAssertEqual(r.keyDown(key: 123, flags: right, repeated: false), .recorded(Chord(123, .superKey)))
        XCTAssertEqual(r.keyDown(key: 53, flags: 0, repeated: false), .cancelled)
        XCTAssertEqual(r.keyDown(key: 12, flags: left, repeated: false), .swallow) // Cmd+Q must not quit anything while recording
        XCTAssertEqual(r.flagsChanged(key: 54, flags: right), .pass); XCTAssertEqual(r.flagsChanged(key: 54, flags: 0), .pass)
    }
}
final class ShortcutTableTests: XCTestCase {
    func testStandardsAreUniqueAllowedAndNamed() {
        let chords = ShellAction.allCases.compactMap(\.standard)
        XCTAssertEqual(Set(chords).count, chords.count); XCTAssertTrue(chords.allSatisfy(\.isAllowed))
        XCTAssertEqual(ShellAction.allCases.compactMap(\.launchIndex), Array(0..<9))
        XCTAssertEqual(ShellAction.launch5.standard?.label, "Super+5"); XCTAssertEqual(ShellAction.launch6.standard?.label, "Super+6")
        XCTAssertEqual(ShellAction.moveLeft.standard?.label, "Super+Shift+←")
    }
    func testConflictsAndBareKeysAreRefused() {
        var t = ShortcutTable()
        XCTAssertEqual(t.set(.center, Chord(123, .superKey)), .taken(.tileLeft))
        XCTAssertEqual(t.set(.center, Chord(8, [])), .notAllowed); XCTAssertEqual(t.set(.center, Chord(8, .shift)), .notAllowed); XCTAssertEqual(t.set(.center, Chord(200, .superKey)), .notAllowed)
        XCTAssertNil(t.set(.center, Chord(8, .superKey))); XCTAssertEqual(t.action(for: Chord(8, .superKey)), .center)
        XCTAssertNil(t.set(.center, Chord(8, .superKey))) // its own chord again
        XCTAssertNil(t.set(.center, nil)); XCTAssertNil(t.action(for: Chord(8, .superKey)))
    }
    func testOnlyChangesAreStoredAndSwapsSurvive() {
        XCTAssertEqual(String(decoding: ShortcutTable().stored, as: UTF8.self), "{}")
        var t = ShortcutTable(); let left = ShellAction.tileLeft.standard, right = ShellAction.tileRight.standard
        _ = t.set(.tileLeft, nil); _ = t.set(.tileRight, left); _ = t.set(.tileLeft, right); _ = t.set(.appGrid, nil)
        XCTAssertEqual(ShortcutTable(stored: t.stored), t)
        XCTAssertEqual(ShortcutTable(stored: Data("junk".utf8)), ShortcutTable()); XCTAssertEqual(ShortcutTable(stored: nil), ShortcutTable())
    }
    func testAltTabSessionsEndOnTheirOwnModifier() {
        var r = KeyRouter(); let option: UInt64 = 0x8_0020, superFlags: UInt64 = 0x10_0010
        XCTAssertEqual(r.keyDown(key: 48, flags: option, repeated: false), .switcher(.begin(windows: false, backwards: false)))
        XCTAssertEqual(r.keyDown(key: 48, flags: option | 0x2_0002, repeated: true), .switcher(.next(backwards: true)))
        XCTAssertEqual(r.keyDown(key: 0, flags: option, repeated: false), .swallow) // nothing else reaches an app meanwhile
        XCTAssertEqual(r.flagsChanged(key: 56, flags: option), .pass) // Shift let go first
        XCTAssertEqual(r.keyUp(key: 48), .swallow)
        XCTAssertEqual(r.flagsChanged(key: 58, flags: 0), .switcher(.commit))
        XCTAssertFalse(r.switching)
        XCTAssertEqual(r.keyDown(key: 50, flags: superFlags, repeated: false), .switcher(.begin(windows: true, backwards: false)))
        XCTAssertEqual(r.flagsChanged(key: 58, flags: superFlags | 0x8_0020), .pass) // another modifier is not the end
        XCTAssertEqual(r.keyDown(key: 53, flags: superFlags, repeated: false), .switcher(.cancel))
        XCTAssertEqual(r.flagsChanged(key: 54, flags: 0), .pass) // and no Super tap after it
        XCTAssertEqual(r.keyDown(key: 48, flags: superFlags, repeated: false), .switcher(.begin(windows: false, backwards: false)))
        XCTAssertTrue(r.reset()); XCTAssertFalse(r.reset())
    }
    func testLeftCommandTabIsMnomesUnlessTurnedOff() {
        var r = KeyRouter(); let left: UInt64 = 0x10_0008
        XCTAssertEqual(r.keyDown(key: 48, flags: left, repeated: false), .switcher(.begin(windows: false, backwards: false)))
        XCTAssertEqual(r.keyDown(key: 48, flags: left | 0x2_0002, repeated: false), .switcher(.next(backwards: true)))
        XCTAssertEqual(r.flagsChanged(key: 54, flags: left | 0x10), .pass) // the right one too: still the left's session
        XCTAssertEqual(r.flagsChanged(key: 54, flags: left), .pass)
        XCTAssertEqual(r.flagsChanged(key: 55, flags: 0), .switcher(.commit))
        XCTAssertEqual(r.keyDown(key: 50, flags: left | 0x2_0002, repeated: false), .switcher(.begin(windows: true, backwards: true)))
        XCTAssertTrue(r.reset())
        XCTAssertEqual(r.keyDown(key: 48, flags: left | 0x8_0020, repeated: false), .pass) // Command+Option+Tab is not a switch
        r.commandTab = false
        XCTAssertEqual(r.keyDown(key: 48, flags: left, repeated: false), .pass)
    }
    func testTheMacsMissionControlLaunchpadAndSpacesKeys() {
        var r = KeyRouter()
        XCTAssertEqual(r.keyDown(key: 160, flags: 0x80_0000, repeated: false), .superTap) // with Fn, as the top row sends it
        XCTAssertEqual(r.keyUp(key: 160), .swallow)
        XCTAssertEqual(r.keyDown(key: 131, flags: 0, repeated: false), .run(.appGrid))
        XCTAssertEqual(r.keyDown(key: 160, flags: 0x10_0008, repeated: false), .pass) // with Command it is someone else's
        XCTAssertEqual(r.keyDown(key: 124, flags: 0x4_0000, repeated: false), .run(.workspaceNext))
        XCTAssertEqual(r.keyDown(key: 123, flags: 0x6_0000, repeated: false), .run(.carryPrevious))
    }
    func testRightOptionAsSuperLeavesLeftOptionForTheSwitcher() {
        var r = KeyRouter(); r.superKey = .rightOption
        XCTAssertEqual(r.keyDown(key: 48, flags: 0x8_0020, repeated: false), .switcher(.begin(windows: false, backwards: false)))
        XCTAssertEqual(r.flagsChanged(key: 61, flags: 0x8_0020 | 0x40), .pass)
        XCTAssertEqual(r.flagsChanged(key: 58, flags: 0x8_0040), .switcher(.commit)) // only the left one started it
    }
    func testWorkspaceKeysAndGNOMEsSecondKeys() {
        var table = ShortcutTable()
        XCTAssertEqual(table.action(for: Chord(124, [.superKey, .option])), .workspaceNext)
        XCTAssertEqual(table.action(for: Chord(121, .superKey)), .workspaceNext)
        XCTAssertNil(table.set(.lock, Chord(121, .superKey))) // a second key gives way to the person's choice
        XCTAssertEqual(table.action(for: Chord(121, .superKey)), .lock)
    }
    func testAPersonsOwnKeysWinOverANewStandard() throws {
        let stored = try JSONEncoder().encode(["lock": Chord(124, [.superKey, .option])] as [String: Chord?])
        let table = ShortcutTable(stored: stored)
        XCTAssertEqual(table.action(for: Chord(124, [.superKey, .option])), .lock)
        XCTAssertNil(table.chords[.workspaceNext])
    }
}
