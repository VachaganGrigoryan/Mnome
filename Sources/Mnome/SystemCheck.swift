import AppKit
import CoreAudio
import CoreWLAN
import MnomeSupport
import ScreenCaptureKit

/// Phase 1: the facts about macOS everything else rests on, so a macOS update that breaks one is noticed here.
/// `--system-check` touches nothing but its own windows; `--system-check settings` also changes settings and the pointer, and puts them back.
@MainActor enum SystemCheck {
    static func run() -> Never {
        if CommandLine.arguments.contains("gaps") { print(NSScreen.screens.map { "\($0.frame.maxY - $0.visibleFrame.maxY) \($0.safeAreaInsets.top)" }.joined(separator: "\n")); exit(0) }
        if CommandLine.arguments.contains("rescue") { let ok = Settings.putBack(); print(ok ? "Settings are as they were." : "Some settings could not be put back."); exit(ok ? 0 : 1) }
        Live.run("system check") {
            guard Settings.putBack() else { throw Live.Stop("an earlier check left settings that could not be put back: \(Settings.file.path)") }
            try await windows(); try await keys(); controls()
            if CommandLine.arguments.contains("settings") { try await settings() }
        }
    }

    // Windows

    private static func windows() async throws {
        let helper = try Live.Windows(); defer { helper.stop() }
        guard helper.ids.count == 4 else { throw Live.Stop("helper windows \(helper.ids)") }
        let seen = await Live.wait { ((try? WindowRegistry.list(helper.pid))?.count ?? 0) >= 4 }
        let refs = (try? WindowRegistry.list(helper.pid)) ?? []
        Live.check("every window is known by its number, though all share one title", seen && Set(refs.compactMap { Private.windowID($0).map(UInt64.init) }).isSuperset(of: helper.ids.values), "\(refs.map { Private.windowID($0) }) want \(helper.ids)")

        let displays = WindowManager.displayFrames()
        guard let main = displays.first, let corner = Parking.corner(displays: displays, main: main) else { Live.skip("parking", "no display corner is free in this arrangement"); return }
        let names = ["one", "two", "fixed"], before = names.reduce(into: [String: CGRect]()) { $0[$1] = helper.frame($1) }
        var slivers: [String] = []
        for name in names + ["stubborn"] {
            guard let ref = refs.first(where: { Private.windowID($0).map(UInt64.init) == helper.ids[name] }), let frame = try? ref.frame() else { throw Live.Stop("lost window \(name)") }
            let start = Date(); _ = try? ref.place(CGRect(origin: Parking.origin(size: frame.size, corner: corner, main: main), size: frame.size)); let took = Date().timeIntervalSince(start) * 1000
            await Live.sleep(0.3)
            guard name != "stubborn" else { continue }
            let visible = displays.map { $0.intersection(helper.frame(name) ?? .null) }.first { !$0.isNull && $0.width > 0 } ?? .zero
            slivers.append(String(format: "%@ %.0f×%.0f pt in %.0f ms", name, visible.width, visible.height, took))
        }
        Live.note(slivers.joined(separator: ", "))
        Live.check("windows park in a corner, leaving a sliver of 2 points at most", names.allSatisfy { name in displays.allSatisfy { let s = $0.intersection(helper.frame(name) ?? .infinite); return s.isNull || min(s.width, s.height) <= 2 } }, "\(names.map { String(describing: helper.frame($0)) })")
        Live.check("one that refuses is noticed by reading it back", helper.frame("stubborn").map { !Parking.isParked($0, displays: displays) } ?? false, "\(String(describing: helper.frame("stubborn")))")

        if CGPreflightScreenCaptureAccess() {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            var wrong: [String] = [], times: [Int] = []
            for name in names {
                guard let window = content.windows.first(where: { UInt64($0.windowID) == helper.ids[name] }) else { wrong.append("\(name) not listed"); continue }
                let config = SCStreamConfiguration(); config.width = 210; config.height = 154; let start = Date()
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                times.append(Int(Date().timeIntervalSince(start) * 1000))
                if !matches(image, EngineWindows.colours[name]!) { wrong.append("\(name) \(image.width)×\(image.height)") }
            }
            Live.check("parked windows are captured, in the right colours", wrong.isEmpty, "\(wrong)"); Live.note("captures took \(times) ms")
        } else { Live.skip("capturing parked windows", "no Screen Recording") }

        for name in names { if let ref = refs.first(where: { Private.windowID($0).map(UInt64.init) == helper.ids[name] }) { _ = try? ref.place(before[name]!) } }
        await Live.sleep(0.3)
        Live.check("and return to the exact place", names.allSatisfy { helper.frame($0) == before[$0] }, "\(names.map { String(describing: helper.frame($0)) }) want \(before)")
    }
    /// By hue: a display's colour profile shifts the rest.
    private static func matches(_ image: CGImage, _ want: NSColor) -> Bool {
        guard let got = NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height * 2 / 3)?.usingColorSpace(.sRGB), let want = want.usingColorSpace(.sRGB) else { return false }
        let apart = abs(got.hueComponent - want.hueComponent)
        return min(apart, 1 - apart) < 0.08 && got.saturationComponent > 0.5 && got.alphaComponent > 0.9
    }

    // Keys, through Mnome's own tap

    private static func keys() async throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "dev.mnome.shell").isEmpty else { Live.skip("Super key", "Mnome is running and would act on the keys"); return }
        let window = try Keys(); defer { window.release(); window.stop() }
        try await window.toFront()
        guard await window.reaches(8, with: 55, Keys.left) else { throw Live.Stop("simulated keys do not reach the test window") }
        // First without the tap: this proves the test below would notice the app switcher.
        try await window.chord(48, with: 55, Keys.left); let switched = !window.isFront
        var seen: [KeyRouter.Decision] = []; let table = ShortcutTable()
        let tap = EventTap(); tap.onDecision = { seen.append($0) }; tap.configure(table, .rightCommand, recording: false)
        guard tap.start() else { Live.check("the keyboard tap opens", false); return }; defer { tap.stop() }

        if switched { try await window.chord(48); Live.check("right Cmd+Tab is caught before the Mac's app switcher, for Mnome's own", seen.first == .switcher(.begin(windows: false, backwards: false)) && window.isFront, "\(seen), in front \(window.isFront)") } else { Live.skip("right Cmd+Tab before the app switcher", "left Cmd+Tab switched nothing either, so this would prove nothing") }
        try await window.toFront(); await Live.sleep(0.5)
        seen = []; await window.tap(54, Keys.right); Live.check("right Cmd alone is a Super tap", seen == [.superTap], "\(seen)")
        seen = []; await window.tap(55, Keys.left); Live.check("left Cmd alone is not", seen.isEmpty, "\(seen)")
        seen = []; try await window.chord(123, extra: Keys.arrow); Live.check("a listed shortcut runs, and is no Super tap", seen == [.run(.tileLeft)], "\(seen)")
        Live.check("and never reaches the app", window.received(123) == 0)
        seen = []; let passed = await window.reaches(8, with: 54, Keys.right); Live.check("any other right Cmd combination reaches the app", passed && seen.isEmpty, "\(passed) \(seen)")
        seen = []; let mac = await window.reaches(123, with: 55, Keys.left); Live.check("left Cmd combinations are the Mac's", mac && seen.isEmpty, "\(mac) \(seen)")
    }

    // System controls

    private static func controls() {
        let readable = NSScreen.screens.map { screen -> (id: CGDirectDisplayID, name: String, value: Float?) in let id = CGDirectDisplayID(WindowManager.displayID(screen)); return (id, screen.localizedName, Private.brightness(id)) }
        Live.note("brightness: " + readable.map { "\($0.name) \($0.value.map { String(format: "%.0f%%", $0 * 100) } ?? "unsupported")" }.joined(separator: ", "))
        if let builtIn = readable.first(where: { CGDisplayIsBuiltin($0.id) != 0 }) { Live.check("the built-in display's brightness can be read and set", builtIn.value.map { Private.setBrightness(builtIn.id, $0) } ?? false) } else { Live.skip("brightness", "no built-in display is on") }

        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size), address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        var volume: Float32 = 0, settable = DarwinBoolean(false), control = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain); size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(device, &control) { let read = AudioObjectGetPropertyData(device, &control, 0, nil, &size, &volume); AudioObjectIsPropertySettable(device, &control, &settable); Live.check("the volume can be read and set", read == noErr && settable.boolValue, "error \(read) settable \(settable)") } else { Live.skip("volume", "this output has none") }

        Live.check("dark style can be read", Private.darkStyle != nil)
        Live.check("Night Light can be read", Private.nightLight != nil)
        Live.check("Bluetooth can be read", Private.bluetoothOn != nil)
        if let wifi = CWWiFiClient.shared().interface() { Live.note("Wi-Fi \(wifi.powerOn() ? "on" : "off"), its name is \(wifi.ssid() == nil ? "hidden without Location" : "visible")") } else { Live.skip("Wi-Fi", "no interface") }
        Live.skip("switching Wi-Fi and Bluetooth", "it would cut the network and wireless keyboards")
    }

    // Settings, with the originals on disk before anything changes

    private struct Saved: Codable { var dark: Bool?, night: Bool?, menuBar: PrefValue? }
    @MainActor private enum Settings {
        static var file: URL { WindowManager.defaultJournal.deletingLastPathComponent().appendingPathComponent("system-check.json") }
        private static let store = CFPreferencesStore()
        static var menuBar: PrefValue { CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost); return store.get("NSGlobalDomain", "_HIHideMenuBar") }
        static func setMenuBar(_ value: PrefValue) { store.set("NSGlobalDomain", "_HIHideMenuBar", value); DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true) }
        static func save(_ saved: Saved) throws { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(saved).write(to: file, options: .atomic) }
        /// True when nothing is left to put back.
        static func putBack() -> Bool {
            guard FileManager.default.fileExists(atPath: file.path) else { return true }
            guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return false }
            if let dark = saved.dark, Private.darkStyle != dark { Private.setDarkStyle(dark) }
            if let night = saved.night, Private.nightLight?.on != night { _ = Private.setNightLight(night) }
            if let value = saved.menuBar, menuBar != value { setMenuBar(value) }
            for _ in 0..<15 {
                if saved.dark.map({ Private.darkStyle == $0 }) ?? true, saved.night.map({ Private.nightLight?.on == $0 }) ?? true, saved.menuBar.map({ menuBar == $0 }) ?? true { try? FileManager.default.removeItem(at: file); return true }
                usleep(200_000)
            }
            return false
        }
    }
    private static func settings() async throws {
        let automatic = CFPreferencesCopyValue("AppleInterfaceStyleSwitchesAutomatically" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool ?? false
        let dark = automatic ? nil : Private.darkStyle, night = Private.nightLight.flatMap { $0.scheduled ? nil : $0.on }, menuBar = Settings.menuBar
        try Settings.save(Saved(dark: dark, night: night, menuBar: menuBar))
        do { // whatever happens below, the settings go back before the result is told
            if let dark { Private.setDarkStyle(!dark); Live.check("dark style switches", await Live.wait { Private.darkStyle == !dark }); Private.setDarkStyle(dark); _ = await Live.wait { Private.darkStyle == dark } } else { Live.skip("switching dark style", automatic ? "the appearance is automatic" : "not available") }
            if let night { let asked = Private.setNightLight(!night); Live.check("Night Light switches", await Live.wait { Private.nightLight?.on == !night } && asked); _ = Private.setNightLight(night); _ = await Live.wait { Private.nightLight?.on == night } } else { Live.skip("switching Night Light", "it follows a schedule, or is not available") }
            try await menuBarCheck(original: menuBar)
        } catch { Live.check("settings", false, "\(error)") }
        Live.check("every setting is as it was", Settings.putBack() && Settings.menuBar == menuBar && (dark == nil || Private.darkStyle == dark) && (night == nil || Private.nightLight?.on == night))
    }
    /// What a fresh process sees: how much of the top each screen keeps, and its notch. This one keeps an old answer.
    private static func gaps() async throws -> [(gap: Double, notch: Double)] {
        try await Live.finish(["--system-check", "gaps"]).output.split(separator: "\n").compactMap { let n = $0.split(separator: " ").compactMap { Double($0) }; return n.count == 2 ? (n[0], n[1]) : nil }
    }
    private static func menuBarCheck(original: PrefValue) async throws {
        if original == .bool(true) { Live.skip("hiding the menu bar", "it is hidden already") } else {
            let before = try await gaps()
            Settings.setMenuBar(.bool(true))
            var hidden: [(gap: Double, notch: Double)] = []; for _ in 0..<8 { await Live.sleep(0.5); hidden = try await gaps(); if hidden.allSatisfy({ $0.gap <= $0.notch }) { break } }
            let shown = before.indices.filter { before[$0].gap > before[$0].notch } // none on a display showing a full-screen app
            if shown.isEmpty { Live.skip("hiding the menu bar", "no display shows it") } else { Live.check("the menu bar hides at once, without Automation", hidden.count == before.count && shown.allSatisfy { hidden[$0].gap <= hidden[$0].notch }, "before \(before) hidden \(hidden)") }
        }
        let pointer = CGEvent(source: nil)?.location; defer { if let pointer { CGWarpMouseCursorPosition(pointer) } }
        await Live.sleep(1)
        for screen in NSScreen.screens { await bar(on: screen) }
    }
    private final class Counter: NSView { var clicks = 0; override func mouseDown(with event: NSEvent) { clicks += 1 }; override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } }
    private static func mouse(_ type: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
    private static func glide(to p: CGPoint) async { let a = CGEvent(source: nil)?.location ?? p; for i in 1...12 { let f = CGFloat(i) / 12; mouse(.mouseMoved, CGPoint(x: a.x + (p.x - a.x) * f, y: a.y + (p.y - a.y) * f)); await Live.sleep(0.015) } }
    /// Our bar's place at the top edge: front to back, true for ours.
    private static func topWindows(_ screen: NSScreen, _ ours: Int) -> [Bool] {
        let top = WindowManager.primaryHeight - screen.frame.maxY
        return (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { w in
            guard let layer = w[kCGWindowLayer as String] as? Int, let raw = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: raw), layer >= 20, layer < 1000, b.minY <= top + 2, b.minY >= top - 60, b.midX >= screen.frame.minX, b.midX <= screen.frame.maxX, b.height < 60, b.width > 200 else { return nil }
            return w[kCGWindowNumber as String] as? Int == ours
        }
    }
    private static func bar(on screen: NSScreen) async {
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - 32, width: screen.frame.width, height: 32), view = Counter()
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: 24); panel.backgroundColor = .black; panel.collectionBehavior = [.canJoinAllSpaces, .stationary]; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.contentView = view
        panel.setFrame(frame, display: true); panel.orderFrontRegardless(); defer { panel.orderOut(nil) }; await Live.sleep(0.5)
        let flip = { (x: CGFloat, y: CGFloat) in CGPoint(x: x, y: WindowManager.primaryHeight - y) }
        Live.check("\(screen.localizedName): our bar stays at the top edge", panel.frame == frame, "\(panel.frame) want \(frame)")
        var tried = 0
        for side in [0.25, 0.75] {
            let at = NSPoint(x: frame.minX + frame.width * side, y: frame.maxY - 20); await glide(to: flip(at.x, at.y)); await Live.sleep(0.15)
            guard NSWindow.windowNumber(at: at, belowWindowWithWindowNumber: 0) == panel.windowNumber else { continue } // never click another app
            tried += 1; mouse(.leftMouseDown, flip(at.x, at.y)); await Live.sleep(0.05); mouse(.leftMouseUp, flip(at.x, at.y)); await Live.sleep(0.25)
        }
        Live.check("\(screen.localizedName): it receives every click, on both sides", tried == 2 && view.clicks == 2, "\(view.clicks) of \(tried), tried 2")
        let edge = flip(frame.minX + frame.width * 0.25, frame.maxY); await glide(to: CGPoint(x: edge.x, y: edge.y + 1)); for _ in 0..<10 { mouse(.mouseMoved, edge); await Live.sleep(0.03) }
        let revealed = await Live.wait(3) { topWindows(screen, panel.windowNumber).first == false }
        Live.check("\(screen.localizedName): the Mac menus appear above it at the top edge", revealed, "\(topWindows(screen, panel.windowNumber))")
        await glide(to: flip(screen.frame.midX, screen.frame.midY)); await Live.sleep(1.2)
    }
}
