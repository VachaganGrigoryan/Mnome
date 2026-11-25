import AppKit
import MnomeSupport

/// What the checks that drive the real macOS share. They move only windows of their own.
@MainActor enum Live {
    struct Stop: Error, CustomStringConvertible { let description: String; init(_ text: String) { description = text } }
    private(set) static var failures = 0, skipped = 0
    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { if !ok { failures += 1 }; print(ok ? "ok   " : "FAIL ", name, ok ? "" : detail()); fflush(stdout) }
    /// Not tested here, which is not the same as passed.
    static func skip(_ name: String, _ why: String) { skipped += 1; print("skip ", name, "—", why); fflush(stdout) }
    static func note(_ text: String) { print("      \(text)"); fflush(stdout) }
    static func wait(_ seconds: Double = 5, _ done: () -> Bool) async -> Bool { let end = Date().addingTimeInterval(seconds); while Date() < end { if done() { return true }; try? await Task.sleep(for: .milliseconds(50)) }; return done() }
    static func until(_ seconds: Double = 5, _ done: () async -> Bool) async -> Bool { let end = Date().addingTimeInterval(seconds); while Date() < end { if await done() { return true }; try? await Task.sleep(for: .milliseconds(100)) }; return await done() }
    static func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    static func near(_ a: CGRect?, _ b: CGRect) -> Bool { a.map { IntentLedger.close($0, b) } ?? false }
    static func frame(_ pid: pid_t, _ id: UInt64) -> CGRect? { (try? WindowRegistry.list(pid))?.first { Private.windowID($0).map(UInt64.init) == id }.flatMap { try? $0.frame() } }
    /// Runs the check and exits with the number of failures.
    static func run(_ name: String, _ body: @escaping @MainActor () async throws -> Void) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0); signal(SIGPIPE, SIG_IGN) // a helper that quit must not end the check
        guard AXIsProcessTrusted() else { print("The \(name) needs Accessibility."); exit(1) }
        guard !AwayMonitor.locked else { print("The screen is locked: unlock it to run the \(name)."); exit(1) }
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { do { try await body() } catch { check("setup", false, "\(error)") }; if AwayMonitor.locked { print("The screen was locked meanwhile, so this result means nothing."); exit(1) }; print(failures == 0 ? "\(name) passed" : "\(name): \(failures) failed", skipped == 0 ? "" : "(\(skipped) skipped)"); exit(Int32(min(failures, 100))) }
        NSApplication.shared.run(); exit(1)
    }
    /// Another copy of this program, which ends when its standard input does.
    @MainActor class Child {
        let process = Process(), input = Pipe(), output = Pipe()
        init(_ arguments: [String]) throws { process.executableURL = Bundle.main.executableURL; process.arguments = arguments; process.standardInput = input; process.standardOutput = output; try process.run() }
        var pid: pid_t { process.processIdentifier }
        func tell(_ command: String) { try? input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8)) }
        func stop() { process.terminate() }
    }
    /// Runs this program to its end without blocking the main thread.
    static func finish(_ arguments: [String]) async throws -> (status: Int32, reason: Process.TerminationReason, output: String) {
        let process = Process(), output = Pipe(); process.executableURL = Bundle.main.executableURL; process.arguments = arguments; process.standardOutput = output; try process.run()
        let text = await Task.detached { let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return String(decoding: data, as: UTF8.self) }.value
        return (process.terminationStatus, process.terminationReason, text)
    }
    @MainActor final class Windows: Child {
        private(set) var ids: [String: UInt64] = [:]
        init() throws {
            try super.init(["--engine-windows"])
            let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            for pair in line.split(whereSeparator: \.isWhitespace) { let kv = pair.split(separator: "="); if kv.count == 2 { ids[String(kv[0])] = UInt64(kv[1]) } }
        }
        func frame(_ name: String) -> CGRect? { ids[name].flatMap { Live.frame(pid, $0) } }
        /// A window opened after the start; macOS reports its number on standard output.
        func open(_ name: String, at place: String = "") { tell("open \(name) \(place)"); let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self); ids[name] = UInt64(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

/// Throwaway windows in their own process. Commands arrive on standard input.
@MainActor enum EngineWindows {
    static let colours: [String: NSColor] = ["one": .red, "two": .green, "fixed": .blue, "stubborn": .magenta]
    /// Goes back to where it was whenever moved, until a time: as an app busy animating.
    private final class Clinging: NSObject, NSWindowDelegate {
        let place: NSPoint, until: Date
        init(_ place: NSPoint, _ seconds: Double) { self.place = place; until = Date().addingTimeInterval(seconds) }
        func windowDidMove(_ note: Notification) { guard Date() < until, let w = note.object as? NSWindow, w.frame.origin != place else { return }; DispatchQueue.main.async { w.setFrameOrigin(self.place) } }
    }
    private final class Stubborn: NSObject, NSWindowDelegate {
        func windowDidMove(_ note: Notification) { guard let w = note.object as? NSWindow, let v = NSScreen.screens.first?.visibleFrame, !v.contains(w.frame) else { return }; DispatchQueue.main.async { w.setFrameOrigin(NSPoint(x: v.midX - 200, y: v.midY - 150)) } }
    }
    static func run() -> Never {
        let app = NSApplication.shared; app.setActivationPolicy(.regular) // as ordinary apps, which macOS can hide
        let stubborn = Stubborn(); var windows: [String: NSWindow] = [:]; nonisolated(unsafe) var clinging: Clinging? // main thread only
        func make(_ title: String, _ i: Int) {
            let w = NSWindow(contentRect: NSRect(x: 200 + i * 60, y: 200 + i * 40, width: 420, height: 280), styleMask: title == "fixed" ? [.titled, .closable, .miniaturizable] : [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Mnome engine check"; w.isReleasedWhenClosed = false; w.backgroundColor = colours[title] ?? .gray; w.collectionBehavior = .fullScreenPrimary; if title == "stubborn" { w.delegate = stubborn } // all share one title on purpose
            w.orderFrontRegardless(); windows[title] = w
        }
        for (i, title) in ["one", "two", "fixed", "stubborn"].enumerated() { make(title, i) }
        print(["one", "two", "fixed", "stubborn"].map { "\($0)=\(windows[$0]!.windowNumber)" }.joined(separator: " ")); fflush(stdout)
        Thread.detachNewThread { while let line = readLine() { let parts = line.split(separator: " ").map(String.init); DispatchQueue.main.async { MainActor.assumeIsolated { switch parts[0] {
            case "open": make(parts[1], 5); if parts.count > 3 { windows[parts[1]]!.setFrameOrigin(NSPoint(x: Double(parts[2])!, y: Double(parts[3])!)) }; print(windows[parts[1]]!.windowNumber); fflush(stdout)
            case "cling": if let w = windows[parts[1]] { clinging = Clinging(w.frame.origin, Double(parts[2])!); w.delegate = clinging }
            case "reopen": app.activate(); windows[parts[1]]?.makeKeyAndOrderFront(nil)
            case "hide": app.hide(nil)
            case "unhide": app.unhideWithoutActivation()
            case "panel": let p = NSPanel(contentRect: NSRect(x: 500, y: 500, width: 240, height: 120), styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false); p.isReleasedWhenClosed = false; p.orderFrontRegardless(); windows["panel"] = p
            case "close": windows[parts[1]]?.close()
            case "minimize": windows[parts[1]]?.miniaturize(nil)
            case "fullscreen": windows[parts[1]]?.toggleFullScreen(nil)
            case "move": windows[parts[1]]?.setFrameOrigin(NSPoint(x: Double(parts[2])!, y: Double(parts[3])!))
            default: break
        } } } }; exit(0) } // the check ended
        app.run(); exit(0)
    }
}

/// An ordinary app with one window that reports the Command keys it receives, so simulated keys never reach the person's apps.
@MainActor enum KeyWindow {
    private final class Window: NSWindow {
        override func performKeyEquivalent(with event: NSEvent) -> Bool { print("key \(event.keyCode)"); fflush(stdout); return true } // touches no clipboard
        override func keyDown(with event: NSEvent) {}
    }
    static func run() -> Never {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let w = Window(contentRect: NSRect(x: 300, y: 260, width: 560, height: 380), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Mnome key check"; w.isReleasedWhenClosed = false; w.makeKeyAndOrderFront(nil); app.activate()
        Thread.detachNewThread { while readLine() != nil {}; exit(0) }
        app.run(); exit(0)
    }
}

/// Simulated keys, pressed only while the test window is in front.
@MainActor final class Keys: Live.Child {
    nonisolated static let right: UInt64 = 0x10_0010, left: UInt64 = 0x10_0008, shift: UInt64 = 0x2_0002, arrow: UInt64 = 0xA0_0000
    private let source = CGEventSource(stateID: .hidSystemState), lock = NSLock()
    private nonisolated(unsafe) var log = ""
    init() throws {
        try super.init(["--key-window"])
        output.fileHandleForReading.readabilityHandler = { [weak self] in let text = String(decoding: $0.availableData, as: UTF8.self); self?.lock.withLock { self?.log += text } }
    }
    func received(_ key: CGKeyCode) -> Int { lock.withLock { log.split(separator: "\n").filter { $0 == "key \(key)" }.count } }
    var isFront: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
    func toFront() async throws {
        let app = AXUIElementCreateApplication(pid)
        for _ in 0..<20 { if isFront { return }; AXUIElementSetAttributeValue(app, "AXFrontmost" as CFString, kCFBooleanTrue); await Live.sleep(0.2) }
        release(); throw Live.Stop("the test window could not come to the front")
    }
    func post(_ key: CGKeyCode, _ down: Bool, _ flags: UInt64) { guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }; e.flags = CGEventFlags(rawValue: flags); e.post(tap: .cghidEventTap); usleep(30_000) }
    func release() { for key in [56, 55, 54] as [CGKeyCode] { post(key, false, 0) } }
    /// A lone press of a modifier.
    func tap(_ key: CGKeyCode, _ flags: UInt64) async { post(key, true, flags); post(key, false, 0); await Live.sleep(1.2) }
    func chord(_ key: CGKeyCode, with modifier: CGKeyCode = 54, _ flags: UInt64 = Keys.right, shift: Bool = false, extra: UInt64 = 0, settle: Double = 1.3) async throws {
        try await toFront()
        let all = flags | (shift ? Keys.shift : 0)
        post(modifier, true, flags); if shift { post(56, true, all) }
        post(key, true, all | extra); post(key, false, all | extra)
        if shift { post(56, false, flags) }; post(modifier, false, 0); await Live.sleep(settle)
    }
    /// Whether the combination reaches the test window, exactly once.
    func reaches(_ key: CGKeyCode, with modifier: CGKeyCode, _ flags: UInt64) async -> Bool {
        guard isFront else { return false }
        let before = received(key); post(modifier, true, flags); post(key, true, flags); post(key, false, flags); post(modifier, false, 0); await Live.sleep(0.6)
        return received(key) == before + 1
    }
}
