import AppKit
import MnomeSupport

/// Throwaway windows for the engine check, in their own process. Commands arrive on standard input.
@MainActor enum EngineWindows {
    private final class Stubborn: NSObject, NSWindowDelegate {
        func windowDidMove(_ note: Notification) { guard let w = note.object as? NSWindow, let v = NSScreen.screens.first?.visibleFrame, !v.contains(w.frame) else { return }; DispatchQueue.main.async { w.setFrameOrigin(NSPoint(x: v.midX - 200, y: v.midY - 150)) } }
    }
    static func run() -> Never {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let stubborn = Stubborn(); var windows: [String: NSWindow] = [:]
        for (i, title) in ["one", "two", "fixed", "stubborn"].enumerated() {
            let w = NSWindow(contentRect: NSRect(x: 200 + i * 60, y: 200 + i * 40, width: 420, height: 280), styleMask: title == "fixed" ? [.titled, .closable, .miniaturizable] : [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Mnome engine check"; w.isReleasedWhenClosed = false; if title == "stubborn" { w.delegate = stubborn } // all share one title on purpose
            w.orderFrontRegardless(); windows[title] = w
        }
        print(["one", "two", "fixed", "stubborn"].map { "\($0)=\(windows[$0]!.windowNumber)" }.joined(separator: " ")); fflush(stdout)
        Thread.detachNewThread { while let line = readLine() { let parts = line.split(separator: " ").map(String.init); DispatchQueue.main.async { MainActor.assumeIsolated { switch parts[0] {
            case "close": windows[parts[1]]?.close()
            case "move": windows[parts[1]]?.setFrameOrigin(NSPoint(x: Double(parts[2])!, y: Double(parts[3])!))
            default: break
        } } } }; exit(0) } // the check ended
        app.run(); exit(0)
    }
}

/// Drives the real engine against those windows only, and exits with the number of failures.
@MainActor enum EngineCheck {
    private static var failures = 0
    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { if !ok { failures += 1 }; print(ok ? "ok   " : "FAIL ", name, ok ? "" : detail()); fflush(stdout) }
    private static func wait(_ seconds: Double = 5, _ done: () -> Bool) async -> Bool { let end = Date().addingTimeInterval(seconds); while Date() < end { if done() { return true }; try? await Task.sleep(for: .milliseconds(50)) }; return done() }
    private final class Helper {
        let process = Process(), input = Pipe(); private(set) var ids: [String: UInt64] = [:]
        init() throws {
            let output = Pipe(); process.executableURL = Bundle.main.executableURL; process.arguments = ["--engine-windows"]; process.standardInput = input; process.standardOutput = output; try process.run()
            let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            for pair in line.split(whereSeparator: \.isWhitespace) { let kv = pair.split(separator: "="); if kv.count == 2 { ids[String(kv[0])] = UInt64(kv[1]) } }
        }
        var pid: pid_t { process.processIdentifier }
        func tell(_ command: String) { try? input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8)) }
    }
    private static func frame(_ helper: Helper, _ name: String) -> CGRect? {
        guard let id = helper.ids[name], let refs = try? WindowRegistry.list(helper.pid) else { return nil }
        return refs.first { Private.windowID($0).map(UInt64.init) == id }.flatMap { try? $0.frame() }
    }
    private static func near(_ a: CGRect?, _ b: CGRect) -> Bool { a.map { IntentLedger.close($0, b) } ?? false }

    static func run() -> Never {
        guard AXIsProcessTrusted() else { print("The engine check needs Accessibility."); exit(1) }
        NSApplication.shared.setActivationPolicy(.accessory)
        if let flag = CommandLine.arguments.firstIndex(of: "--engine-check"), CommandLine.arguments.indices.contains(flag + 3), CommandLine.arguments[flag + 1] == "crash" { crash(pid_t(CommandLine.arguments[flag + 2])!, URL(fileURLWithPath: CommandLine.arguments[flag + 3])) }
        Task { do { try await all() } catch { check("setup", false, "\(error)") }; print(failures == 0 ? "engine check passed" : "\(failures) failed"); exit(Int32(failures)) }
        NSApplication.shared.run(); exit(1)
    }
    private static func manager(_ pid: pid_t, _ journal: URL) -> WindowManager { let m = WindowManager(journal: journal); m.registry.only = [pid]; m.start(); return m }
    /// Parks two windows, then dies without any clean-up.
    private static func crash(_ pid: pid_t, _ journal: URL) -> Never {
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
        let helper = try Helper(); defer { helper.process.terminate() }
        let displays = WindowManager.displayFrames()
        guard helper.ids.count == 4, let one = helper.ids["one"], let two = helper.ids["two"], let fixed = helper.ids["fixed"], let stubborn = helper.ids["stubborn"] else { check("helper windows", false, "\(helper.ids)"); return }
        var m = manager(helper.pid, journal)
        let tracked = await wait { m.state?.windows.count == 4 }
        check("tracks four windows with one title, by number", tracked && Set(m.state!.windows.map(\.id)) == Set(helper.ids.values), "\(m.state?.windows.map(\.id) ?? []) expected \(helper.ids)")
        guard tracked, let area = NSScreen.screens.first.map({ WMRect(WorkArea.flip($0.visibleFrame, primaryHeight: WindowManager.primaryHeight)).cgRect }) else { return }
        let start = frame(helper, "one")!

        m.send(.activate(one)); _ = m.focus(one)
        var front: UInt64?; for _ in 0..<40 { front = await m.registry.focusedWindow(); if front == one { break }; try? await Task.sleep(for: .milliseconds(50)) }
        check("focuses one of several same-titled windows, and knows it is in front", front == one, "\(String(describing: front)) want \(one)")

        m.send(.snap(one, .left)); m.send(.snap(two, .right))
        let left = CGRect(x: area.minX, y: area.minY, width: (area.width / 2).rounded(.down), height: area.height)
        check("snaps to halves", await wait { near(frame(helper, "one"), left) && near(frame(helper, "two"), CGRect(x: left.maxX, y: area.minY, width: area.width - left.width, height: area.height)) }, "\(String(describing: frame(helper, "one"))) \(String(describing: frame(helper, "two"))) want \(left)")
        m.send(.toggleMaximize(one))
        check("maximizes", await wait { near(frame(helper, "one"), area) }, "\(String(describing: frame(helper, "one"))) want \(area)")
        m.send(.restore(one))
        check("restores the free frame", await wait { near(frame(helper, "one"), start) }, "\(String(describing: frame(helper, "one"))) want \(start)")
        let fixedSize = frame(helper, "fixed")!.size
        m.send(.snap(fixed, .left))
        _ = await wait(3) { near(frame(helper, "fixed").map { CGRect(origin: $0.origin, size: left.size) }, left) }
        check("a fixed-size window moves without being resized", frame(helper, "fixed")?.size == fixedSize && frame(helper, "fixed")?.minX == left.minX, "\(String(describing: frame(helper, "fixed")))")
        try? await Task.sleep(for: .seconds(1))
        check("our own moves are not taken for the person's", m.state?.window(two)?.rect.x == Int(left.maxX))

        helper.tell("move one 300 300")
        let moved = await wait { frame(helper, "one")?.minX == 300 && m.state?.window(one)?.rect.x == 300 }
        check("the person's move is recorded", moved, "\(String(describing: m.state?.window(one)?.rect)) frame \(String(describing: frame(helper, "one")))")

        for x in stride(from: 310, through: 500, by: 10) { helper.tell("move one \(x) 260"); try? await Task.sleep(for: .milliseconds(25)) }
        check("a drag ends where the person left it", await wait { frame(helper, "one")?.minX == 500 && m.state?.window(one)?.rect.x == 500 }, "\(String(describing: m.state?.window(one)?.rect)) frame \(String(describing: frame(helper, "one")))")
        check("a second copy is refused the recovery file", !RecoveryJournal(url: journal).acquire())

        let before = frame(helper, "one")!, other = m.state!.workspaces.last!, home = m.state!.current
        m.send(.toWorkspace(one, other))
        check("parks a window of another workspace", await wait { frame(helper, "one").map { Parking.isParked($0, displays: displays) } ?? false }, "\(String(describing: frame(helper, "one")))")
        check("and its record is on disk first", RecoveryJournal(url: journal).records.contains { $0.window == one && $0.original == before })
        m.send(.toWorkspace(stubborn, other))
        check("a window that refuses stays, on every workspace", await wait { m.state?.window(stubborn)?.sticky == true }, "\(String(describing: m.state?.window(stubborn)))")
        m.send(.setWorkspace(other))
        check("switching swaps what is shown", await wait { near(frame(helper, "one"), before) && (frame(helper, "two").map { Parking.isParked($0, displays: displays) } ?? false) }, "one \(String(describing: frame(helper, "one"))) two \(String(describing: frame(helper, "two")))")
        m.send(.setWorkspace(home))
        check("and back, to the exact tile", await wait { frame(helper, "two")?.minX == left.maxX && (frame(helper, "one").map { Parking.isParked($0, displays: displays) } ?? false) })
        for _ in 0..<4 { m.send(.setWorkspace(other)); m.send(.setWorkspace(home)) }
        check("fast switching settles on the last choice", await wait { frame(helper, "two")?.minX == left.maxX && (frame(helper, "one").map { Parking.isParked($0, displays: displays) } ?? false) }, "one \(String(describing: frame(helper, "one"))) two \(String(describing: frame(helper, "two")))")
        m.send(.toWorkspace(one, home))
        check("bringing it back empties the journal", await wait { near(frame(helper, "one"), before) && RecoveryJournal(url: journal).records.isEmpty }, "\(RecoveryJournal(url: journal).records)")

        m.send(.minimize(one))
        let shown = { (name: String) -> Bool? in (try? WindowRegistry.list(helper.pid))?.first { Private.windowID($0).map(UInt64.init) == helper.ids[name] }.flatMap { try? !$0.flag("AXMinimized") } }
        check("minimizes", await wait { shown("one") == false && m.registry.windows[one]?.minimized == true && m.state?.window(one)?.minimized == true })
        m.send(.activate(one))
        check("and returns", await wait { shown("one") == true && m.registry.windows[one]?.minimized == false && near(frame(helper, "one"), before) })
        helper.tell("close fixed")
        check("forgets a closed window", await wait { m.state?.window(fixed) == nil && m.registry.windows[fixed] == nil })

        kill(helper.pid, SIGSTOP); let t = Date()
        m.send(.snap(one, .right)); let blocked = Date().timeIntervalSince(t)
        try? await Task.sleep(for: .seconds(4))
        check("a hung app never blocks us and loses no window", blocked < 0.1 && m.state?.windows.count == 3, "blocked \(blocked)s, windows \(m.state?.windows.count ?? 0)")
        kill(helper.pid, SIGCONT); try? await Task.sleep(for: .seconds(3))
        m.send(.snap(one, .left))
        check("and works again afterwards", await wait(8) { near(frame(helper, "one"), left) }, "\(String(describing: frame(helper, "one"))) want \(left)")

        let parkedNow = { ["one", "two"].allSatisfy { frame(helper, $0).map { Parking.isParked($0, displays: displays) } ?? false } }
        let far = m.state!.workspaces.last!; m.send(.toWorkspace(one, far)); m.send(.toWorkspace(two, far))
        check("parks two before quitting", await wait { parkedNow() && RecoveryJournal(url: journal).records.filter { $0.parked != nil }.count == 2 }, "\(RecoveryJournal(url: journal).records)")
        let t2 = Date(); m.shutDown()
        check("quitting brings every window back", ["one", "two"].allSatisfy { !Parking.isParked(frame(helper, $0)!, displays: displays) } && RecoveryJournal(url: journal).records.isEmpty, "\(RecoveryJournal(url: journal).records)")
        print("      in", String(format: "%.0f ms", Date().timeIntervalSince(t2) * 1000))

        let original = ["one", "two"].map { frame(helper, $0)! }, child = Process()
        child.executableURL = Bundle.main.executableURL; child.arguments = ["--engine-check", "crash", String(helper.pid), journal.path]; child.standardOutput = FileHandle.nullDevice
        try child.run(); await Task.detached { child.waitUntilExit() }.value
        let parked = ["one", "two"].filter { Parking.isParked(frame(helper, $0)!, displays: displays) }
        check("a crash leaves two windows parked, recorded", child.terminationReason == .uncaughtSignal && parked.count == 2 && RecoveryJournal(url: journal).records.count == 2, "parked \(parked) status \(child.terminationStatus)")
        m = manager(helper.pid, journal)
        check("the next launch puts them back exactly", await wait { zip(["one", "two"], original).allSatisfy { near(frame(helper, $0), $1) } && RecoveryJournal(url: journal).records.isEmpty && m.state?.windows.count == 3 }, "\(["one", "two"].map { String(describing: frame(helper, $0)) }) want \(original)")

        m.send(.toWorkspace(one, m.state!.workspaces.last!))
        check("parks one before its app quits", await wait { RecoveryJournal(url: journal).records.filter { $0.parked != nil }.count == 1 })
        helper.process.terminate()
        check("an app that quits while parked is forgotten", await wait { m.state?.windows.isEmpty == true && RecoveryJournal(url: journal).records.isEmpty }, "\(m.state?.windows.count ?? -1) windows, \(RecoveryJournal(url: journal).records.count) records")
        m.shutDown()
    }
}
