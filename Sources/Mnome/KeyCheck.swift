import AppKit
import MnomeSupport

/// Phase 3: presses simulated keys at the running Mnome, with a window of its own in front.
/// Super+D also minimizes the person's windows for a moment and checks that each returns exactly, so it runs only with `--key-check desktop`.
@MainActor enum KeyCheck {
    private static var mnome: pid_t? { NSRunningApplication.runningApplications(withBundleIdentifier: "dev.mnome.shell").first?.processIdentifier }
    private static func listed() -> [[String: Any]] { CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [] }
    /// A tall Mnome window above the desktop: Mnome's own desktop, at the desktop's level, is not one.
    private static var overview: Bool { listed().contains { $0[kCGWindowOwnerPID as String] as? Int32 == mnome && ($0[kCGWindowLayer as String] as? Int ?? 0) >= 0 && (($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.height ?? 0) > 500 } }
    private static func frame(_ pid: pid_t) -> CGRect { (try? WindowRegistry.list(pid))?.first.flatMap { try? $0.frame() } ?? .null }

    static func run() -> Never { Live.run("key check") {
        guard mnome != nil else { throw Live.Stop("Mnome is not running") }
        let keys = try Keys(); defer { keys.release(); keys.stop() }
        guard let screen = NSScreen.screens.first?.frame else { return }
        try await keys.toFront(); await Live.sleep(2.5) // Mnome notices the new app
        if overview { await keys.tap(54, Keys.right); try await keys.toFront() }
        guard !overview else { throw Live.Stop("an overview is open and would not close") }
        Live.check("the test window gets the keyboard", await keys.reaches(8, with: 55, Keys.left))
        let start = frame(keys.pid), now = { frame(keys.pid) }

        await keys.tap(54, Keys.right); Live.check("1 right Cmd opens Activities", overview)
        await keys.tap(54, Keys.right); Live.check("1 and closes it", !overview)
        Live.check("1 the keyboard returns to the app by itself", await keys.reaches(8, with: 55, Keys.left), "in front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        if UserDefaults(suiteName: "dev.mnome.shell")?.object(forKey: "hotCorner") as? Bool ?? true {
            await push(into: .zero, by: 30); Live.check("H a light touch of the corner opens nothing", !overview)
            await push(into: .zero, by: 140); Live.check("H pushing into the top-left corner opens the overview", overview)
            await keys.tap(54, Keys.right); Live.check("H and Super closes it", !overview)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 600, y: 400), mouseButton: .left)?.post(tap: .cghidEventTap)
            try await keys.toFront()
        }
        try await keys.chord(123, extra: Keys.arrow); let l = now(); Live.check("2 Super+Left tiles left", abs(l.minX) <= 1 && abs(l.width - screen.width / 2) <= 1 && l.height > screen.height * 0.7, "\(l)")
        try await keys.chord(124, extra: Keys.arrow); let r = now(); Live.check("2 Super+Right tiles right", abs(r.minX - screen.width / 2) <= 1 && abs(r.width - screen.width / 2) <= 1, "\(r)")
        try await keys.chord(124, extra: Keys.arrow); Live.check("3 Super+Right again restores", now() == start, "\(now()) want \(start)")
        try await keys.chord(126, extra: Keys.arrow); let m = now(); Live.check("4 Super+Up maximizes", abs(m.minX) <= 1 && abs(m.width - screen.width) <= 1, "\(m)")
        try await keys.chord(125, extra: Keys.arrow); Live.check("4 Super+Down restores", now() == start, "\(now()) want \(start)")
        try await keys.chord(125, extra: Keys.arrow); Live.check("4 Super+Down again does nothing", now() == start, "\(now()) want \(start)")
        if NSScreen.screens.contains(where: { $0.frame.minX >= screen.maxX }) {
            try await keys.chord(124, shift: true, extra: Keys.arrow); Live.check("5 Super+Shift+Right moves to the other display", now().minX >= screen.maxX, "\(now())")
            try await keys.chord(123, shift: true, extra: Keys.arrow); Live.check("5 and back to the exact place", now() == start, "\(now()) want \(start)")
        } else { Live.skip("5 moving between displays", "no display to the right") }
        Live.check("7 right Cmd+C reaches the app", await keys.reaches(8, with: 54, Keys.right)); Live.check("7 and opens nothing", !overview)
        let before = now(); Live.check("7 left Cmd+Left is the app's", await keys.reaches(123, with: 55, Keys.left) && now() == before, "\(now())")
        try await keys.chord(21, shift: true); keys.post(53, true, 0); keys.post(53, false, 0); await Live.sleep(0.8) // Esc ends the screenshot
        Live.check("8 right Cmd+Shift+4 opens no Activities", !overview)
        if CommandLine.arguments.contains("workspaces") { try await workspaces(keys) } else { Live.skip("workspaces and Alt+Tab", "they park every window for a moment; add `workspaces` to include them") }
        if CommandLine.arguments.contains("desktop") { try await desktop(keys) } else { Live.skip("6 Super+D", "it minimizes every window; add `desktop` to include it") }
    } }

    /// Every other app's windows, by number: frame and whether it is in the corner.
    /// The pointer stops at the corner; the mouse keeps reporting movement, in steps of 10.
    private static func push(into corner: CGPoint, by total: Int) async {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 300, y: 300), mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(150))
        for _ in 0..<(total / 10) {
            let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: corner, mouseButton: .left)
            event?.setDoubleValueField(.mouseEventDeltaX, value: -10); event?.setIntegerValueField(.mouseEventDeltaX, value: -10)
            event?.post(tap: .cghidEventTap); try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(600))
    }
    private static func others(_ keys: Keys) -> [UInt32: CGRect] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != "dev.mnome.shell" && $0.processIdentifier != keys.pid && !$0.isHidden }.reduce(into: [:]) { found, app in
            for ref in (try? WindowRegistry.list(app.processIdentifier)) ?? [] { if let id = Private.windowID(ref), (try? ref.flag("AXMinimized")) == false, (try? ref.value("AXSubrole") as? String) == "AXStandardWindow", let frame = try? ref.frame() { found[id] = frame } }
        }
    }
    private static var popup: Bool { listed().contains { $0[kCGWindowOwnerPID as String] as? Int32 == mnome && (($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }.map { $0.height < 100 && $0.width < 600 && $0.minY > 300 } ?? false) } }
    private static func moved(_ before: [UInt32: CGRect], _ now: [UInt32: CGRect]) -> [String] { before.compactMap { id, was in now[id].map { $0 == was ? nil : "\(id) \(was) → \($0)" } ?? "\(id) gone" } }
    /// The slide between workspaces: a Mnome window over every app and under the bar.
    private static var cover: Bool { listed().contains { $0[kCGWindowOwnerPID as String] as? Int32 == mnome && $0[kCGWindowLayer as String] as? Int == 26 } }
    /// Right Command with Option, and Shift if asked, then an arrow.
    private static func workspaceKey(_ keys: Keys, _ key: CGKeyCode, shift: Bool = false) async {
        let option: UInt64 = 0x8_0020, all = Keys.right | option | (shift ? Keys.shift : 0)
        keys.post(54, true, Keys.right); keys.post(58, true, Keys.right | option); if shift { keys.post(56, true, all) }
        keys.post(key, true, all | Keys.arrow); keys.post(key, false, all | Keys.arrow)
        if shift { keys.post(56, false, Keys.right | option) }; keys.post(58, false, Keys.right); keys.post(54, false, 0); await Live.sleep(0.15)
    }
    private static func workspaces(_ keys: Keys) async throws {
        try await keys.toFront(); let mine = frame(keys.pid), before = others(keys), displays = WindowManager.displayFrames()
        let main = displays[0], onMain = before.filter { main.contains(CGPoint(x: $0.value.midX, y: $0.value.midY)) }
        let parked = { (f: CGRect?) in f.map { Parking.isParked($0, displays: displays) } ?? false }
        let back = { others(keys) == before }
        await workspaceKey(keys, 124, shift: true); let shown = await Live.wait(1) { popup }; await Live.sleep(1.5)
        Live.check("W1 Super+Option+Shift+→ takes the window to a new workspace", frame(keys.pid) == mine && onMain.keys.allSatisfy { parked(others(keys)[$0]) }, "\(frame(keys.pid)) want \(mine), parked \(onMain.keys.filter { parked(others(keys)[$0]) }.count) of \(onMain.count)")
        Live.check("W1 with a row of dots", shown)
        Live.check("W1 and the keyboard stays with it", keys.isFront)
        let pressed = Date(); await workspaceKey(keys, 123); let covered = await Live.wait(0.5) { cover }, uncovered = await Live.wait(2) { !cover }, took = Date().timeIntervalSince(pressed)
        if CGPreflightScreenCaptureAccess(), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { Live.check("W2 the screen slides, and the slide is gone within a second", covered && uncovered && took < 1, "covered \(covered), gone after \(Int(took * 1000)) ms") }
        await Live.sleep(1.5)
        Live.check("W2 Super+Option+← goes back: every window exactly where it was", parked(frame(keys.pid)) && back(), "\(moved(before, others(keys)))")
        Live.check("W2 and the keyboard is on a window in sight", NSWorkspace.shared.frontmostApplication?.processIdentifier != keys.pid)
        await workspaceKey(keys, 124); await Live.sleep(1.5)
        Live.check("W3 Super+Option+→ shows it again, exactly", frame(keys.pid) == mine, "\(frame(keys.pid)) want \(mine)")
        try await keys.toFront(); await workspaceKey(keys, 123, shift: true); await Live.sleep(1.5)
        Live.check("W4 and Shift+← brings it home, with everything else as it was", frame(keys.pid) == mine && back(), "\(before.filter { others(keys)[$0.key] != $0.value }.count) moved")

        try await keys.toFront(); await Live.sleep(0.5)
        let option: UInt64 = 0x8_0020
        keys.post(58, true, option); keys.post(48, true, option); keys.post(48, false, option); keys.post(58, false, 0); await Live.sleep(1)
        Live.check("A1 a quick Option+Tab goes to the app before", !keys.isFront && NSWorkspace.shared.frontmostApplication?.processIdentifier != mnome)
        keys.post(58, true, option); keys.post(48, true, option); keys.post(48, false, option); keys.post(58, false, 0); await Live.sleep(1)
        Live.check("A1 and again comes back", keys.isFront)
        keys.post(58, true, option); keys.post(48, true, option); keys.post(48, false, option); await Live.sleep(0.5)
        let big = listed().contains { $0[kCGWindowOwnerPID as String] as? Int32 == mnome && ($0[kCGWindowLayer as String] as? Int ?? 0) == Int(CGWindowLevelForKey(.popUpMenuWindow)) }
        keys.post(53, true, option); keys.post(53, false, option); keys.post(58, false, 0); await Live.sleep(1)
        Live.check("A2 held, it shows the applications", big)
        Live.check("A2 Escape changes nothing", keys.isFront)
        keys.post(54, true, Keys.right); keys.post(48, true, Keys.right); keys.post(48, false, Keys.right); keys.post(54, false, 0); await Live.sleep(1)
        Live.check("A3 right Cmd+Tab switches too, and opens no Activities", !keys.isFront && !overview)
        try await keys.toFront()
        Live.check("A4 typing still reaches the app", await keys.reaches(8, with: 55, Keys.left))
    }
    private static func desktop(_ keys: Keys) async throws {
        struct Seen: Hashable { let app: pid_t, frame: CGRect, shown: Bool }
        let all = { () -> [UInt32: Seen] in
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != "dev.mnome.shell" }.reduce(into: [:]) { found, app in
                for ref in (try? WindowRegistry.list(app.processIdentifier)) ?? [] { if let id = Private.windowID(ref), let frame = try? ref.frame() { found[id] = Seen(app: app.processIdentifier, frame: frame, shown: (try? ref.flag("AXMinimized")) == false) } }
            }
        }
        let mine = { (seen: [UInt32: Seen]) in seen.values.first { $0.app == keys.pid } }, count = { (seen: [UInt32: Seen]) in seen.values.filter(\.shown).count }
        let before = all(); try await keys.chord(2, settle: 2.5); let hidden = all()
        Live.check("6 Super+D hides the windows", mine(hidden)?.shown == false && count(hidden) < count(before), "shown \(count(before)) → \(count(hidden))")
        for seen in hidden where seen.value.shown { Live.note("still shown: \(NSRunningApplication(processIdentifier: seen.value.app)?.localizedName ?? "?")") }
        keys.post(54, true, Keys.right); keys.post(2, true, Keys.right); keys.post(2, false, Keys.right); keys.post(54, false, 0) // no window is in front to protect
        let back = await Live.wait(8) { all() == before }
        Live.check("6 and again brings every window back exactly", back, "\(before.filter { all()[$0.key] != $0.value }) became \(all().filter { before[$0.key] != $0.value })")
    }
}
