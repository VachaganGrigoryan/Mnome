import AppKit
import MnomeSupport

/// Phase 3: presses simulated keys at the running Mnome, with a window of its own in front.
/// Super+D also minimizes the person's windows for a moment and checks that each returns exactly, so it runs only with `--key-check desktop`.
@MainActor enum KeyCheck {
    private static var mnome: pid_t? { NSRunningApplication.runningApplications(withBundleIdentifier: "dev.mnome.shell").first?.processIdentifier }
    private static func listed() -> [[String: Any]] { CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [] }
    private static var overview: Bool { listed().contains { $0[kCGWindowOwnerPID as String] as? Int32 == mnome && (($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.height ?? 0) > 500 } }
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
        if CommandLine.arguments.contains("desktop") { try await desktop(keys) } else { Live.skip("6 Super+D", "it minimizes every window; add `desktop` to include it") }
    } }

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
