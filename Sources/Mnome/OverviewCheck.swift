import AppKit

/// `--overview-check`: opens and closes the running Mnome's overview with real key events and prints its own timing.
/// Nothing moves: it only covers the screen for a moment each time.
enum OverviewCheck {
    static func run() -> Never {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "dev.mnome.shell").contains(where: { $0.processIdentifier != getpid() }) else { print("Mnome is not running."); exit(2) }
        let domain = "dev.mnome.shell" as CFString
        CFPreferencesSetAppValue("overviewTiming" as CFString, kCFBooleanTrue, domain); CFPreferencesAppSynchronize(domain)
        defer { CFPreferencesSetAppValue("overviewTiming" as CFString, nil, domain); CFPreferencesAppSynchronize(domain) }
        try? FileManager.default.removeItem(at: FrameMeter.file)
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ key: CGKeyCode, _ down: Bool, _ flags: UInt64) { CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down).map { $0.flags = CGEventFlags(rawValue: flags); $0.post(tap: .cghidEventTap) }; usleep(30_000) }
        func superTap() { post(54, true, 0x10_0010); post(54, false, 0) }
        func escape() { post(53, true, 0); post(53, false, 0) }
        for _ in 0..<10 { superTap(); usleep(900_000); escape(); usleep(800_000) }
        for _ in 0..<3 { post(54, true, 0x10_0010); post(0, true, 0x10_0010); post(0, false, 0x10_0010); post(54, false, 0); usleep(900_000); escape(); usleep(800_000) }
        superTap(); usleep(900_000)
        for key: CGKeyCode in [1, 14, 17, 17, 34] { post(key, true, 0); post(key, false, 0); usleep(120_000) } // "setti"
        usleep(800_000); escape(); usleep(300_000); escape(); usleep(800_000)
        let lines = ((try? String(contentsOf: FrameMeter.file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        func values(_ kind: String, _ key: String) -> [Double] { lines.filter { $0.hasPrefix(kind + " ") }.compactMap { $0.split(separator: " ").first { $0.hasPrefix(key + "=") }.flatMap { Double($0.dropFirst(key.count + 1).replacingOccurrences(of: "ms", with: "")) } } }
        func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
        for kind in ["open", "close", "open-apps"] {
            let first = values(kind, "first"), dropped = values(kind, "dropped"), worst = values(kind, "worst")
            print(String(format: "%-9@ n=%d  first frame median %.0f ms max %.0f  dropped frames median %.0f max %.0f  worst gap max %.1f ms", kind as NSString, first.count, median(first), first.max() ?? .nan, median(dropped), dropped.max() ?? .nan, worst.max() ?? .nan))
        }
        for line in lines where line.hasPrefix("search") { print(line) }
        exit(lines.isEmpty ? 1 : 0)
    }
}
