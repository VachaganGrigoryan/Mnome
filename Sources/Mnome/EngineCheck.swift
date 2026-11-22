import AppKit
import MnomeSupport

/// Phase 2: drives the real engine against windows of its own. `--engine-check apps` uses fresh copies of real apps instead.
@MainActor enum EngineCheck {
    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { Live.check(name, ok, detail()) }
    private static func wait(_ seconds: Double = 5, _ done: () -> Bool) async -> Bool { await Live.wait(seconds, done) }
    private static func near(_ a: CGRect?, _ b: CGRect) -> Bool { Live.near(a, b) }

    static func run() -> Never {
        if let flag = CommandLine.arguments.firstIndex(of: "--engine-check"), CommandLine.arguments.indices.contains(flag + 3), CommandLine.arguments[flag + 1] == "crash" { crash(pid_t(CommandLine.arguments[flag + 2])!, URL(fileURLWithPath: CommandLine.arguments[flag + 3])) }
        Live.run("engine check") { if CommandLine.arguments.contains("apps") { try await apps() } else { try await all() } }
    }
    private static func manager(_ pid: pid_t, _ journal: URL) -> WindowManager { let m = WindowManager(journal: journal); m.registry.only = [pid]; m.start(); return m }
    /// Parks two windows, then dies without any clean-up.
    private static func crash(_ pid: pid_t, _ journal: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        let m = manager(pid, journal)
        Task {
            _ = await wait { m.state?.windows.count ?? 0 >= 3 }
            let ids = (m.state?.windows ?? []).filter { !$0.sticky }.map(\.id).sorted().prefix(2)
            for id in ids { m.send(.toWorkspace(id, m.state!.workspaces.last!)) }
            _ = await wait { RecoveryJournal(url: journal).records.filter { $0.parked != nil }.count == 2 }
            kill(getpid(), SIGKILL)
        }
        NSApplication.shared.run(); exit(1)
    }
    private static func all() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mnome-engine-\(getpid())"), journal = folder.appendingPathComponent("parked.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = try Live.Windows(); defer { helper.stop() }
        let displays = WindowManager.displayFrames()
        guard helper.ids.count == 4, let one = helper.ids["one"], let two = helper.ids["two"], let fixed = helper.ids["fixed"], let stubborn = helper.ids["stubborn"] else { check("helper windows", false, "\(helper.ids)"); return }
        var m = manager(helper.pid, journal)
        let tracked = await wait { m.state?.windows.count == 4 }
        check("tracks four windows with one title, by number", tracked && Set(m.state!.windows.map(\.id)) == Set(helper.ids.values), "\(m.state?.windows.map(\.id) ?? []) expected \(helper.ids)")
        guard tracked, let area = NSScreen.screens.first.map({ WMRect(WorkArea.flip($0.visibleFrame, primaryHeight: WindowManager.primaryHeight)).cgRect }) else { return }
        let start = helper.frame("one")!

        m.send(.activate(one)); _ = m.focus(one)
        var front: UInt64?; for _ in 0..<40 { front = await m.registry.focusedWindow(); if front == one { break }; try? await Task.sleep(for: .milliseconds(50)) }
        check("focuses one of several same-titled windows, and knows it is in front", front == one, "\(String(describing: front)) want \(one)")

        m.send(.snap(one, .left)); m.send(.snap(two, .right))
        let left = CGRect(x: area.minX, y: area.minY, width: (area.width / 2).rounded(.down), height: area.height)
        check("snaps to halves", await wait { near(helper.frame("one"), left) && near(helper.frame("two"), CGRect(x: left.maxX, y: area.minY, width: area.width - left.width, height: area.height)) }, "\(String(describing: helper.frame("one"))) \(String(describing: helper.frame("two"))) want \(left)")
        m.send(.toggleMaximize(one))
        check("maximizes", await wait { near(helper.frame("one"), area) }, "\(String(describing: helper.frame("one"))) want \(area)")
        m.send(.restore(one))
        check("restores the free frame", await wait { near(helper.frame("one"), start) }, "\(String(describing: helper.frame("one"))) want \(start)")
        let fixedSize = helper.frame("fixed")!.size
        m.send(.snap(fixed, .left))
        _ = await wait(3) { near(helper.frame("fixed").map { CGRect(origin: $0.origin, size: left.size) }, left) }
        check("a fixed-size window moves without being resized", helper.frame("fixed")?.size == fixedSize && helper.frame("fixed")?.minX == left.minX, "\(String(describing: helper.frame("fixed")))")
        try? await Task.sleep(for: .seconds(1))
        check("our own moves are not taken for the person's", m.state?.window(two)?.rect.x == Int(left.maxX))

        helper.tell("move one 300 300")
        let moved = await wait { helper.frame("one")?.minX == 300 && m.state?.window(one)?.rect.x == 300 }
        check("the person's move is recorded", moved, "\(String(describing: m.state?.window(one)?.rect)) frame \(String(describing: helper.frame("one")))")

        for x in stride(from: 310, through: 500, by: 10) { helper.tell("move one \(x) 260"); try? await Task.sleep(for: .milliseconds(25)) }
        check("a drag ends where the person left it", await wait { helper.frame("one")?.minX == 500 && m.state?.window(one)?.rect.x == 500 }, "\(String(describing: m.state?.window(one)?.rect)) frame \(String(describing: helper.frame("one")))")
        check("a second copy is refused the recovery file", !RecoveryJournal(url: journal).acquire())

        let before = helper.frame("one")!, other = m.state!.workspaces.last!, home = m.state!.current
        m.send(.toWorkspace(one, other))
        check("parks a window of another workspace", await wait { helper.frame("one").map { Parking.isParked($0, displays: displays) } ?? false }, "\(String(describing: helper.frame("one")))")
        check("and its record is on disk first", RecoveryJournal(url: journal).records.contains { $0.window == one && $0.original == before })
        m.send(.toWorkspace(stubborn, other))
        check("a window that refuses stays, on every workspace", await wait { m.state?.window(stubborn)?.sticky == true }, "\(String(describing: m.state?.window(stubborn)))")
        m.send(.setWorkspace(other))
        check("switching swaps what is shown", await wait { near(helper.frame("one"), before) && (helper.frame("two").map { Parking.isParked($0, displays: displays) } ?? false) }, "one \(String(describing: helper.frame("one"))) two \(String(describing: helper.frame("two")))")
        m.send(.setWorkspace(home))
        check("and back, to the exact tile", await wait { helper.frame("two")?.minX == left.maxX && (helper.frame("one").map { Parking.isParked($0, displays: displays) } ?? false) }, "one \(String(describing: helper.frame("one"))) two \(String(describing: helper.frame("two"))) state \(m.state?.windows.map { "\($0.id) ws\($0.workspace) sticky \($0.sticky) \($0.rect)" } ?? []) current \(m.state?.current ?? 0) home \(home) other \(other) journal \(RecoveryJournal(url: journal).records.map(\.window))")
        for _ in 0..<4 { m.send(.setWorkspace(other)); m.send(.setWorkspace(home)) }
        check("fast switching settles on the last choice", await wait { helper.frame("two")?.minX == left.maxX && (helper.frame("one").map { Parking.isParked($0, displays: displays) } ?? false) }, "one \(String(describing: helper.frame("one"))) two \(String(describing: helper.frame("two")))")
        m.send(.toWorkspace(one, home))
        check("bringing it back empties the journal", await wait { near(helper.frame("one"), before) && RecoveryJournal(url: journal).records.isEmpty }, "\(RecoveryJournal(url: journal).records)")

        m.send(.minimize(one))
        let shown = { (name: String) -> Bool? in (try? WindowRegistry.list(helper.pid))?.first { Private.windowID($0).map(UInt64.init) == helper.ids[name] }.flatMap { try? !$0.flag("AXMinimized") } }
        check("minimizes", await wait { shown("one") == false && m.registry.windows[one]?.minimized == true && m.state?.window(one)?.minimized == true })
        m.send(.activate(one))
        check("and returns", await wait { shown("one") == true && m.registry.windows[one]?.minimized == false && near(helper.frame("one"), before) })
        helper.tell("close fixed")
        check("forgets a closed window", await wait { m.state?.window(fixed) == nil && m.registry.windows[fixed] == nil })

        helper.open("late"); let opened = Date()
        check("notices a new window from macOS, not from the sweep", await wait(3) { helper.ids["late"].map { m.state?.window($0) != nil } ?? false } && Date().timeIntervalSince(opened) < 3)
        helper.tell("panel"); await Live.sleep(1.5)
        check("leaves panels alone", m.state?.windows.count == 4, "\(m.state?.windows.count ?? 0) windows")
        helper.tell("minimize late")
        check("sees the person minimize a window", await wait { helper.ids["late"].flatMap { m.state?.window($0) }?.minimized == true })
        m.send(.activate(helper.ids["late"]!)); _ = await wait { shown("late") == true }
        helper.tell("fullscreen two")
        check("sees native full screen", await wait(8) { m.registry.windows[two]?.fullscreen == true })
        m.send(.toWorkspace(two, m.state!.workspaces.last!)); await Live.sleep(1)
        check("and never parks it", helper.frame("two").map { !Parking.isParked($0, displays: displays) } ?? true && !RecoveryJournal(url: journal).records.contains { $0.window == two })
        m.send(.toWorkspace(two, m.state!.current)); await Live.sleep(0.5); helper.tell("fullscreen two")
        check("and takes it back afterwards", await wait(8) { m.registry.windows[two]?.fullscreen == false && m.state?.window(two)?.fullscreen == false }); await Live.sleep(1.5)

        kill(helper.pid, SIGSTOP); let t = Date()
        m.send(.snap(one, .right)); let blocked = Date().timeIntervalSince(t)
        try? await Task.sleep(for: .seconds(4))
        check("a hung app never blocks us and loses no window", blocked < 0.1 && m.state?.windows.count == 4, "blocked \(blocked)s, windows \(m.state?.windows.count ?? 0)")
        kill(helper.pid, SIGCONT); try? await Task.sleep(for: .seconds(3))
        m.send(.snap(one, .left))
        check("and works again afterwards", await wait(8) { near(helper.frame("one"), left) }, "\(String(describing: helper.frame("one"))) want \(left)")

        let parkedNow = { ["one", "two"].allSatisfy { helper.frame($0).map { Parking.isParked($0, displays: displays) } ?? false } }
        let far = m.state!.workspaces.last!; m.send(.toWorkspace(one, far)); m.send(.toWorkspace(two, far))
        check("parks two before quitting", await wait { parkedNow() && RecoveryJournal(url: journal).records.filter { $0.parked != nil }.count == 2 }, "\(RecoveryJournal(url: journal).records)")
        let t2 = Date(); m.shutDown()
        check("quitting brings every window back", ["one", "two"].allSatisfy { !Parking.isParked(helper.frame($0)!, displays: displays) } && RecoveryJournal(url: journal).records.isEmpty, "\(RecoveryJournal(url: journal).records)")
        print("      in", String(format: "%.0f ms", Date().timeIntervalSince(t2) * 1000))

        let names = ["one", "two"], original = names.map { helper.frame($0)! }
        let crashed = { () async throws in
            let child = try await Live.finish(["--engine-check", "crash", String(helper.pid), journal.path])
            let parked = names.filter { Parking.isParked(helper.frame($0)!, displays: displays) }
            check("a crash leaves two windows parked, recorded", child.reason == .uncaughtSignal && parked.count == 2 && RecoveryJournal(url: journal).records.count == 2, "parked \(parked) status \(child.status)")
        }
        let back = { zip(names, original).allSatisfy { near(helper.frame($0), $1) } && RecoveryJournal(url: journal).records.isEmpty }
        try await crashed()
        m = manager(helper.pid, journal)
        check("the next launch puts them back exactly", await wait { back() && m.state?.windows.count == 4 }, "\(names.map { String(describing: helper.frame($0)) }) want \(original)")
        let refused = try await Live.finish(["--rescue", journal.path])
        check("--rescue is refused while a copy is running", refused.status == 1 && refused.output.contains("running"), refused.output)
        m.shutDown()
        try await crashed()
        let rescued = try await Live.finish(["--rescue", journal.path])
        check("--rescue puts them back exactly", rescued.status == 0 && back(), "\(rescued.output) \(names.map { String(describing: helper.frame($0)) }) want \(original)")

        try await crashed()
        kill(helper.pid, SIGKILL); helper.process.waitUntilExit()
        let again = try Live.Windows(); defer { again.stop() }
        _ = await wait { again.ids.allSatisfy { again.frame($0.key) != nil } }
        let fresh = again.ids.keys.reduce(into: [String: CGRect]()) { $0[$1] = again.frame($1) }
        m = manager(again.pid, journal)
        check("an app that restarted after the crash is left where it opened", await wait { m.state?.windows.count == 4 } && again.ids.keys.allSatisfy { again.frame($0) == fresh[$0] } && RecoveryJournal(url: journal).records.isEmpty, "\(fresh) \(RecoveryJournal(url: journal).records)")

        m.send(.toWorkspace(again.ids["one"]!, m.state!.workspaces.last!))
        check("parks one before its app quits", await wait { RecoveryJournal(url: journal).records.filter { $0.parked != nil }.count == 1 })
        again.stop()
        check("an app that quits while parked is forgotten", await wait { m.state?.windows.isEmpty == true && RecoveryJournal(url: journal).records.isEmpty }, "\(m.state?.windows.count ?? -1) windows, \(RecoveryJournal(url: journal).records.count) records")
        m.shutDown()
    }

    // Real apps, as fresh copies with settings of their own where the app allows it

    private static func apps() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mnome-apps-\(getpid())"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try ["One", "Two"].map { name -> URL in let url = folder.appendingPathComponent("Mnome \(name).txt"); try "Made by the Mnome engine check.\n".write(to: url, atomically: true, encoding: .utf8); return url }
        let plain = ["-ApplePersistence", "NO", "-NSQuitAlwaysKeepsWindows", "NO"] // neither reopens nor saves the person's windows
        await app("TextEdit, two windows", "com.apple.TextEdit", plain, files, windows: 2, folder)
        await app("Terminal", "com.apple.Terminal", plain, [], windows: 1, folder)
        await app("Visual Studio Code (Electron)", "com.microsoft.VSCode", ["--user-data-dir=\(folder.path)/code", "--extensions-dir=\(folder.path)/extensions", "--disable-telemetry", "--disable-updates", "--skip-welcome", "--skip-release-notes", "--new-window"], [], windows: 1, folder)
    }
    private static func app(_ name: String, _ bundle: String, _ arguments: [String], _ files: [URL], windows: Int, _ folder: URL) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { Live.skip(name, "not installed"); return }
        let config = NSWorkspace.OpenConfiguration(); config.createsNewApplicationInstance = true; config.arguments = arguments; config.addsToRecentItems = false; config.activates = false
        let mine = { NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundle }.map(\.processIdentifier) }, old = Set(mine())
        guard let app = try? await files.isEmpty ? NSWorkspace.shared.openApplication(at: url, configuration: config) : NSWorkspace.shared.open(files, withApplicationAt: url, configuration: config), !old.contains(app.processIdentifier) else { check("\(name): a copy of its own starts", false); return }
        defer { app.forceTerminate() } // ours, with nothing to save
        let m = manager(app.processIdentifier, folder.appendingPathComponent("\(bundle).json")); defer { m.shutDown() }
        guard await wait(20, { (m.state?.windows.count ?? 0) >= windows }) else { check("\(name): its windows are tracked", false, "\(m.state?.windows.count ?? 0) of \(windows)"); return }
        await Live.sleep(2) // apps adjust their windows just after opening
        guard let ids = m.state?.windows.map(\.id), let home = m.state?.current, let other = m.state?.workspaces.last else { return }
        let displays = WindowManager.displayFrames(), pid = app.processIdentifier, frames = { ids.map { Live.frame(pid, $0) } }
        for (i, id) in ids.enumerated() { if let ref = m.registry.windows[id]?.ref, let main = displays.first { _ = try? ref.place(CGRect(x: main.minX + 120 + 60 * CGFloat(i), y: main.minY + 120, width: 800, height: 500)) } } // the last used display may be another one, where nothing is parked
        let landed = { ids.allSatisfy { id in displays.first.map { main in Live.frame(pid, id).map { main.contains(CGPoint(x: $0.midX, y: $0.midY)) && m.state?.window(id)?.rect == WMRect($0) } ?? false } ?? false } }
        guard await wait(5, landed) else { check("\(name): moves to the main display", false, "\(frames())"); return }
        let before = frames()
        ids.forEach { m.send(.toWorkspace($0, other)) }
        let parked = await wait { frames().allSatisfy { $0.map { Parking.isParked($0, displays: displays) } ?? false } }
        check("\(name): parks", parked, "\(frames()) from \(before)"); guard parked else { return }
        Live.note(frames().map { f in displays.compactMap { d in f.map { d.intersection($0) } }.first { !$0.isNull && $0.width > 0 }.map { "\(Int($0.width))×\(Int($0.height)) pt left" } ?? "nothing left" }.joined(separator: ", "))
        m.send(.setWorkspace(other)); check("\(name): returns to the exact place", await wait { frames() == before }, "\(frames()) want \(before)")
        m.send(.setWorkspace(home)); _ = await wait { frames().allSatisfy { $0.map { Parking.isParked($0, displays: displays) } ?? false } }
        m.shutDown(); check("\(name): and when Mnome quits", frames() == before, "\(frames()) want \(before)")
    }
}
