import AppKit
import MnomeSupport

/// Connects what macOS reports to the core's policy, and carries out what the core asks for.
/// The only writer of window state. Nothing here waits on an app.
@MainActor final class WindowManager: ObservableObject {
    @Published private(set) var state: WMState?
    let registry = WindowRegistry()
    /// Our bar and dock on a screen, in screen coordinates.
    var reserved: (NSScreen) -> (bar: CGRect?, dock: CGRect?) = { _ in (nil, nil) }
    private(set) var running = false
    private let journal: RecoveryJournal, client = AXClient.shared
    private var core: Any = NSNull(), revision: UInt64 = 0, ledger = IntentLedger()
    private var chains: [UInt64: Task<Void, Never>] = [:], originals: [UInt64: CGRect] = [:], records: [UInt64: ParkedRecord] = [:]
    private var screenObserver: NSObjectProtocol?
    let sink = KeyboardSink()
    /// Displays as last given to the core, with their work areas.
    private(set) var displays: [WMDisplay] = []
    /// A move the person makes with the mouse, before the core hears of it. True when it was taken care of.
    var userMoved: (UInt64, CGRect) -> Bool = { _, _ in false }
    /// While the overview shows the Mac Dock, the space it takes is not taken from the windows: nothing moves under it.
    var holdDisplays = false { didSet { if !holdDisplays, heldChange { heldChange = false; displaysChanged() } } }
    private var heldChange = false
    /// Off in Preferences. Also off while Stage Manager is on or no display corner is free.
    var workspacesWanted = UserDefaults.standard.object(forKey: "workspaces") as? Bool ?? true { didSet { UserDefaults.standard.set(workspacesWanted, forKey: "workspaces"); updateDisplays() } }
    /// For the engine check: displays that are not there, to try other arrangements.
    static var extraDisplays: [CGRect] = []
    private var displayWait: Task<Void, Never>?, clicks: Any?, desktopClickAt = Date.distantPast
    private var raising: UInt64?, keyboardOwner: UInt64? // our focus command under way; the visible window that last had the keyboard
    private var unsettled = 0, parkedAgain: [UInt64: Int] = [:], unanswered: Set<UInt64> = [] // counts the times macOS may have moved windows

    nonisolated static var defaultJournal: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mnome/parked.json") }
    init(journal url: URL = WindowManager.defaultJournal) { journal = RecoveryJournal(url: url) }

    func start() {
        guard !running, AXIsProcessTrusted() else { return }
        guard journal.acquire() else { NSLog("Mnome: another copy is managing windows"); return }
        running = true
        updateDisplays()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.displaysChanged() } }
        clicks = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in MainActor.assumeIsolated { if Self.desktopUnderPointer() { self?.desktopClickAt = Date() } } }
        registry.onEvent = { [weak self] in self?.observe($0) }
        registry.away.returned = { [weak self] in self?.settle() }
        Task { if !journal.records.isEmpty { _ = await recover() }; if running { registry.start() } } // before tracking, or parked frames would be taken for real ones
    }
    /// Quitting: the one place that waits, so no window is left in the corner.
    func shutDown() {
        guard running else { return }; running = false
        registry.stop(); chains.values.forEach { $0.cancel() }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        if let clicks { NSEvent.removeMonitor(clicks) }; clicks = nil; displayWait?.cancel()
        RecoveryRunner.restoreBlocking(journal, timeout: 5)
        journal.release()
    }

    // Displays, with a top-left origin from here on

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    static func displayFrames() -> [CGRect] { NSScreen.screens.map { WorkArea.flip($0.frame, primaryHeight: primaryHeight) } + extraDisplays }
    /// macOS rearranges in several steps and moves windows as it goes: wait until it has finished, and take none of it for the person's.
    func displaysChanged() {
        guard running else { return }
        guard !holdDisplays else { heldChange = true; return }
        registry.away.leave("displays"); displayWait?.cancel()
        displayWait = Task { try? await Task.sleep(for: .milliseconds(700)); guard !Task.isCancelled else { return }; updateDisplays(); registry.away.comeBack("displays") }
    }
    private static var stageManager: Bool { UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false }
    private static func desktopUnderPointer() -> Bool {
        let p = NSEvent.mouseLocation, point = CGPoint(x: p.x, y: primaryHeight - p.y)
        let hit = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).first { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.contains(point) ?? false }
        return (hit?[kCGWindowLayer as String] as? Int ?? -1) < 0
    }
    static func displayID(_ screen: NSScreen) -> UInt64 { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint64Value ?? 0 }
    /// Also when our bar or dock appears, moves or goes.
    func updateDisplays() {
        guard running, let main = NSScreen.screens.first else { return } // the first screen has the menu bar
        let displays = NSScreen.screens.map { screen -> WMDisplay in
            let ours = reserved(screen), work = WorkArea.rect(visible: screen.visibleFrame, bar: ours.bar, dock: ours.dock, screenTop: screen.frame.maxY)
            return WMDisplay(id: Self.displayID(screen), frame: WMRect(WorkArea.flip(screen.frame, primaryHeight: Self.primaryHeight)), work: WMRect(WorkArea.flip(work, primaryHeight: Self.primaryHeight)))
        }
        self.displays = displays; send(.displays(displays, main: Self.displayID(main)))
        let frames = Self.displayFrames(), on = workspacesWanted && !Self.stageManager && frames.first.flatMap { Parking.corner(displays: frames, main: $0) } != nil
        if state?.workspacesOn != on { send(.workspacesOn(on)) }
    }

    // Policy

    func send(_ event: WMEvent) {
        do {
            let result = try coreChecked(["version": 1, "op": "wm", "state": core, "event": event.json])
            guard let next = result["state"] else { throw BridgeError.invalidResponse }
            state = try WMState(json: next); core = next; revision = (result["revision"] as? NSNumber)?.uint64Value ?? revision + 1
            let raw = result["ops"] as? [[String: Any]] ?? [], ops = raw.compactMap(WMOp.init(json:))
            if ops.count != raw.count { NSLog("Mnome: unknown window operation in %@", String(describing: raw)) }
            ops.forEach { execute($0, revision) }
            if ops.contains(where: { if case .park = $0 { true } else if case .minimize = $0 { true } else { false } }), state?.focus == nil { keepKeyboardSafe() }
        } catch { NSLog("Mnome: window event refused: %@", String(describing: error)) } // state is unchanged
    }
    var focused: UInt64? { state?.focus }
    /// The snap zone and tile border under a point, in the core's coordinates.
    func hit(_ point: CGPoint) -> WMHit? {
        guard running, let result = try? coreChecked(["version": 1, "op": "wm_hit", "state": core, "x": Int(point.x.rounded()), "y": Int(point.y.rounded())]) else { return nil }
        return WMHit(json: result)
    }
    /// True when the window is known exactly, so no guessing by title is needed.
    /// Waits until no window is being moved or raised by us, or the time is up. True when settled.
    func settled(timeout: Duration) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ledger.busy || raising != nil { guard ContinuousClock.now < end else { return false }; try? await Task.sleep(for: .milliseconds(16)) }
        return true
    }
    func focus(_ id: UInt64) -> Bool { guard running, state?.window(id) != nil else { return false }; send(.activate(id)); raise(id, after: chains[id]); return true }

    /// For shortcuts: acts on the window in front, or on nothing when that is not a window we manage.
    func withFocused(_ make: @escaping (UInt64) -> WMEvent) {
        guard running else { return }
        Task { if let id = await registry.focusedWindow(), state?.isShown(id) == true { send(make(id)) } }
    }
    /// Never one out of sight, even if it has the keyboard.
    func closeFocused() {
        guard running else { registry.closeFocused(); return }
        Task { if let id = await registry.focusedWindow(), state?.window(id) != nil, state?.isShown(id) != true { return }; registry.closeFocused() }
    }
    /// If the keyboard is on a window out of sight, give it to the one that should have it, or to nobody.
    private func keepKeyboardSafe() {
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard running, raising == nil, let id = await registry.focusedWindow(), state?.isShown(id) == false else { return }
            if let wanted = state?.focus, state?.isShown(wanted) == true { raise(wanted, after: chains[wanted]) } else if await sink.take() { keyboardOwner = nil }
        }
    }
    private func observe(_ event: RegistryEvent) {
        switch event {
        case let .opened(w):
            let displays = Self.displayFrames(), known = journal.records.contains { $0.window == w.id && $0.pid == w.pid }
            // Apps place a new window beside a parked one, or where it was when they quit: out of sight either way.
            let returning = records[w.id].flatMap { old in displays.first.map { Recovery.onScreen(old.original, displays: displays, main: $0) } } // closed while parked; macOS may have moved it since
            let astray = returning ?? (w.fresh && !known && !w.minimized && !w.fullscreen && Parking.isParked(w.frame, displays: displays) ? displays.first.map { Recovery.centered(w.frame.size, in: $0) } : nil)
            send(.opened(id: w.id, app: w.app, rect: WMRect(astray ?? w.frame), minimized: w.minimized, fullscreen: w.fullscreen))
            if let astray { carryOut(w.id, .shown(astray), revision) }
            // Left over from an earlier session and only now in reach, for example on another native Space.
            if known, returning == nil { Task { await RecoveryRunner.restore(journal, only: { $0.window == w.id && $0.pid == w.pid }) } }
        case let .closed(id, appEnded):
            chains.removeValue(forKey: id)?.cancel(); ledger.forget(id); originals[id] = nil; parkedAgain[id] = nil; unanswered.remove(id)
            if let record = records[id], appEnded || !WindowServer.lists(id) { records[id] = nil; try? journal.remove(record) } // closed but kept by its app, it may open again in the corner
            send(.closed(id))
        case let .moved(id, frame): moved(id, frame)
        case let .minimized(id, on): send(.minimized(id, on))
        case let .hidden(id, on): send(.hidden(id, on))
        case let .fullscreen(id, on): send(.fullscreen(id, on))
        case let .focused(id): focusReported(id)
        }
    }

    private func focusReported(_ id: UInt64) {
        guard let state, state.window(id) != nil else { return }
        if state.isShown(id) { keyboardOwner = id; send(.focused(id)); return }
        let before = keyboardOwner, beforeApp = before.flatMap { registry.windows[$0]?.pid }, ours = raising != nil || ledger.isPuttingAway(id), app = registry.windows[id].flatMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier }
        Task {
            try? await Task.sleep(for: .milliseconds(250)) // a close or quit that explains it may still be on its way
            let now = await registry.focusedWindow(), ended = beforeApp.map { NSRunningApplication(processIdentifier: $0)?.isTerminated ?? true } ?? false // macOS may say so late
            let owner: FocusGate.Before = before.map { self.state?.isShown($0) == true && !ended ? .shown : .gone } ?? .nothing
            let facts = FocusGate.Facts(before: owner, stillFocused: now == id, ours: ours || raising != nil, desktopClick: Date().timeIntervalSince(desktopClickAt), finder: app == "com.apple.finder")
            switch FocusGate.verdict(facts) {
            case .follow: if self.state?.isShown(id) == false { keyboardOwner = id; send(.focused(id)) }
            case .refuse: keepKeyboardSafe()
            case .ignore: break
            }
        }
    }
    private func moved(_ id: UInt64, _ frame: CGRect) {
        guard !ledger.isEcho(id, frame: frame) else { return }
        if records[id] != nil, Parking.isParked(frame, displays: Self.displayFrames()) {
            // Our corner, not the person's choice. If it should be visible, an earlier attempt failed: try again.
            if let rect = state?.window(id)?.rect, state?.isShown(id) == true { carryOut(id, .shown(exact(id, rect)), revision) }
            return
        }
        if state?.isParked(id) == true, unanswered.remove(id) != nil { carryOut(id, .parked, revision); return }
        if records[id] != nil, state?.isParked(id) == true { // macOS or its app brought it out
            if parkedAgain[id] == unsettled { send(.sticky(id, true)) } else { parkedAgain[id] = unsettled; carryOut(id, .parked, revision) }
            return
        }
        if registry.away.settling, NSEvent.pressedMouseButtons == 0, let window = state?.window(id), state?.isShown(id) == true, !window.fullscreen {
            if Self.display(under: frame) == window.display { carryOut(id, .shown(exact(id, window.rect)), revision) } else { send(.moved(id, WMRect(frame), bySystem: true)) }
            return
        }
        if userMoved(id, frame) { return }
        ledger.forget(id); send(.moved(id, WMRect(frame)))
    }
    /// Back from a lock or sleep: what moved meanwhile was macOS's doing, so windows go back where the person left them.
    private func settle() { guard running else { return }; unsettled += 1; registry.rescanAll() }
    private static func display(under frame: CGRect) -> UInt64? { NSScreen.screens.first { WorkArea.flip($0.frame, primaryHeight: primaryHeight).contains(CGPoint(x: frame.midX, y: frame.midY)) }.map(displayID) }

    // Execution

    private func execute(_ op: WMOp, _ revision: UInt64) {
        switch op {
        case let .focus(id): raise(id, after: chains[id])
        case let .unminimize(id): chain(id) { window in _ = await self.client.run(window.pid) { try window.ref.set("AXMinimized", kCFBooleanFalse) } }
        case let .minimize(id): carryOut(id, .minimized, revision)
        case let .place(id, rect): carryOut(id, .shown(exact(id, rect)), revision)
        case let .unpark(id, rect): carryOut(id, .shown(exact(id, rect)), revision)
        case let .park(id): carryOut(id, .parked, revision)
        }
    }
    /// The core works in whole points; a window that had not moved gets its exact frame back.
    private func exact(_ id: UInt64, _ rect: WMRect) -> CGRect { originals[id].flatMap { WMRect($0) == rect ? $0 : nil } ?? rect.cgRect }
    private func chain(_ id: UInt64, _ work: @escaping @MainActor (TrackedWindow) async -> Void) {
        let previous = chains[id]
        chains[id] = Task { await previous?.value; guard !Task.isCancelled, let window = registry.windows[id] else { return }; await work(window) }
    }
    private func carryOut(_ id: UInt64, _ target: IntentLedger.Target, _ revision: UInt64) {
        ledger.intend(id, target, revision: revision)
        chain(id) { window in
            while self.ledger.isCurrent(id, revision: revision), !Task.isCancelled {
                let (ok, frame) = await self.attempt(window, target)
                var seen = frame
                if case .shown = target, let frame, !Recovery.inSight(frame, displays: Self.displayFrames()) { seen = nil } // not where it belongs, so still to be brought back
                switch self.ledger.finished(id, revision: revision, ok: ok, observed: seen) {
                case .stale: return
                case .retry: try? await Task.sleep(for: .milliseconds(150))
                case .done: self.settled(id, target, frame); self.checkLater(id); return
                case .gaveUp: self.gaveUp(id, target, frame); self.checkLater(id, after: 5); return
                }
            }
        }
    }
    private func attempt(_ window: TrackedWindow, _ target: IntentLedger.Target) async -> (Bool, CGRect?) {
        let client = client, pid = window.pid, ref = window.ref
        switch target {
        case .minimized:
            guard case let .success(minimized) = await client.run(pid, { try ref.set("AXMinimized", kCFBooleanTrue); return try ref.flag("AXMinimized") }) else { return (false, nil) }
            return (minimized, nil)
        case let .shown(rect):
            guard case let .success(frame) = await client.run(pid, { client.pauseEnhancedInterface(pid); return try ref.place(rect) }) else { return (false, nil) }
            return (IntentLedger.close(frame, rect), frame)
        case .parked:
            let displays = Self.displayFrames()
            guard let main = displays.first, let corner = Parking.corner(displays: displays, main: main) else { return (false, nil) }
            // Without a number the window could not be found again after a crash.
            guard window.id < WindowRegistry.firstMadeUpID, case let .success(now) = await client.run(pid, { try ref.frame() }) else { return (false, nil) }
            if Parking.isParked(now, displays: displays) { return (records[window.id] != nil, now) }
            guard let started = ProcessIdentity.started(pid) else { return (false, nil) }
            var record = ParkedRecord(pid: pid, started: started, bundle: window.app, window: window.id, original: records[window.id].flatMap { $0.started == started ? $0.original : nil } ?? now) // out of place it never came back, so the first frame still counts
            do { try journal.put(record) } catch { NSLog("Mnome: not parking, the recovery file could not be written: %@", String(describing: error)); return (false, now) }
            records[window.id] = record; originals[window.id] = record.original
            let parked = await client.run(pid) { client.pauseEnhancedInterface(pid); return try ref.move(to: Parking.origin(size: now.size, corner: corner, main: main)) { Parking.isParked($0, displays: displays) } }
            guard case let .success(frame) = parked, Parking.isParked(frame, displays: displays) else { if case let .success(frame) = parked { return (false, frame) }; return (false, nil) }
            record.parked = frame; records[window.id] = record; try? journal.put(record)
            return (true, frame)
        }
    }
    /// What the person did while we ignored echoes.
    private func checkLater(_ id: UInt64, after delay: TimeInterval = IntentLedger.echo + 0.1) {
        Task { try? await Task.sleep(for: .seconds(delay)); if running, let frame = registry.windows[id]?.frame { moved(id, frame) } }
    }
    /// A record goes only once its window has been read back in sight.
    private func settled(_ id: UInt64, _ target: IntentLedger.Target, _ frame: CGRect?) {
        guard case .shown = target, let frame, Recovery.inSight(frame, displays: Self.displayFrames()) else { return }
        originals[id] = nil
        if let record = records.removeValue(forKey: id) { try? journal.remove(record) } // read back where it belongs
    }
    private func gaveUp(_ id: UInt64, _ target: IntentLedger.Target, _ frame: CGRect?) {
        switch target {
        case .parked where frame == nil: unanswered.insert(id) // its app did not answer: try again later, it may only be busy
        case .parked: send(.sticky(id, true)) // it stays visible on every workspace instead
        case .shown: settled(id, target, frame) // visible, if not exactly where asked
        case .minimized: break
        }
    }
    /// Restored and confirmed first, then focused.
    /// Only once it is in sight, and then read back: the keyboard must never land on a window out of sight.
    private func raise(_ id: UInt64, after work: Task<Void, Never>?) {
        raising = id
        Task {
            defer { if raising == id { raising = nil } }
            await work?.value
            guard let window = registry.windows[id], focused == id, state?.isShown(id) == true else { return }
            let pid = window.pid, ref = window.ref, displays = Self.displayFrames()
            guard case let .success(frame) = await client.run(pid, { try ref.frame() }), Recovery.inSight(frame, displays: displays) else { if raising == id { raising = nil }; keepKeyboardSafe(); return }
            for _ in 0..<2 {
                _ = await client.run(pid) { try? ref.set("AXMain", kCFBooleanTrue); try? AXUIElementCreateApplication(pid).set("AXFrontmost", kCFBooleanTrue); try ref.perform("AXRaise") }
                NSRunningApplication(processIdentifier: pid)?.activate()
                try? await Task.sleep(for: .milliseconds(250))
                guard focused == id else { return } // something newer was asked for
                if await registry.focusedWindow() == id { keyboardOwner = id; return }
            }
            if raising == id { raising = nil }; keepKeyboardSafe()
        }
    }

    // Recovery

    /// Brings back what the journal knows. Returns how many windows could not be brought back.
    func recover() async -> Int { await RecoveryRunner.restore(journal) }
    /// The person's "bring back everything": also windows no record knows about.
    func bringBackAll() async -> Int {
        let failed = await recover()
        for (id, record) in records where !journal.records.contains(where: record.sameWindow) { records[id] = nil; originals[id] = nil; ledger.forget(id) }
        if let state { for window in state.windows where window.workspace != state.current { send(.toWorkspace(window.id, state.current)) } }
        return failed + (await RecoveryRunner.centerStrays())
    }
}

/// Moves parked windows back. Works without the engine, so `--rescue` and a crashed session use the same code.
enum RecoveryRunner {
    private struct Found { let window: LiveWindow, ref: AXUIElement, plain: Bool }
    private static func live(_ apps: [NSRunningApplication]) async -> (windows: [Found], unreadable: Set<Int32>) {
        var windows: [Found] = [], unreadable: Set<Int32> = []
        for app in apps {
            let pid = app.processIdentifier, bundle = app.bundleIdentifier ?? app.bundleURL?.path ?? "pid.\(pid)", started = ProcessIdentity.started(pid) ?? 0
            switch await AXClient.shared.run(pid, urgent: true, { try read(pid, bundle, started) }) {
            case let .success(found): windows += found
            case .failure: unreadable.insert(pid)
            }
        }
        return (windows, unreadable)
    }
    /// One window closing or refusing says nothing about the others; only an app that hangs is unreadable as a whole.
    private static func read(_ pid: pid_t, _ bundle: String, _ started: Double) throws -> [Found] {
        try WindowRegistry.list(pid).compactMap { ref in
            let reading: WindowReading?
            do { reading = try WindowRegistry.read(ref) } catch AXFailure.hung { throw AXFailure.hung } catch { return nil }
            return reading.map { Found(window: LiveWindow(pid: pid, started: started, bundle: bundle, window: $0.number.map(UInt64.init) ?? 0, frame: $0.frame), ref: ref, plain: !$0.minimized && !$0.fullscreen) }
        }
    }
    private static func running(_ records: [ParkedRecord]) -> [Int32: Double] { records.reduce(into: [:]) { $0[$1.pid] = ProcessIdentity.started($1.pid) } }
    private static func apps(for records: [ParkedRecord]) -> [NSRunningApplication] { NSWorkspace.shared.runningApplications.filter { app in records.contains { $0.pid == app.processIdentifier || $0.bundle == app.bundleIdentifier } } }
    /// Displays are read on the main thread; moves run on each app's own queue.
    @discardableResult @MainActor static func restore(_ journal: RecoveryJournal, only: (ParkedRecord) -> Bool = { _ in true }) async -> Int {
        let records = journal.records.filter(only); guard !records.isEmpty else { return 0 }
        let displays = WindowManager.displayFrames(); guard let main = displays.first else { return records.count }
        let (windows, unreadable) = await live(apps(for: records))
        var failed = 0, stuck: Set<String> = []
        let steps = Recovery.steps(records: records, live: windows.map(\.window), running: running(records), displays: displays, main: main)
        for case let .center(window, frame) in steps where !(await put(window, frame, windows, displays)) { failed += 1; stuck.insert(window.bundle) }
        for step in steps {
            switch step {
            case let .drop(record): if !stuck.contains(record.bundle), journal.records.contains(record) { try? journal.remove(record) } // its window may still be in the corner
            case let .keep(record): if unreadable.contains(record.pid) { failed += 1 } // otherwise on another Space, or closed
            case let .restore(record, window, frame):
                // Only the record read at the start: a park meanwhile wrote a new one, which must stay.
                if await put(window, frame, windows, displays) { if journal.records.contains(record) { try? journal.remove(record) } } else { failed += 1 }
            case .center: break
            }
        }
        return failed
    }
    private static func put(_ window: LiveWindow, _ frame: CGRect, _ all: [Found], _ displays: [CGRect]) async -> Bool {
        guard let ref = all.first(where: { $0.window == window })?.ref else { return false }
        for _ in 0..<3 { if case let .success(now) = await AXClient.shared.run(window.pid, urgent: true, { try ref.place(frame) }), Recovery.inSight(now, displays: displays) { return true } }
        return false
    }
    /// Any app's window that only a sliver of is visible. Only when the person asks: another tool may have put it there.
    @MainActor static func centerStrays() async -> Int {
        let displays = WindowManager.displayFrames(); guard let main = displays.first else { return 0 }
        let (windows, _) = await live(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isHidden })
        var failed = 0
        for found in windows where found.plain && Parking.isParked(found.window.frame, displays: displays) {
            if !(await put(found.window, Recovery.centered(found.window.frame.size, in: main), windows, displays)) { failed += 1 }
        }
        return failed
    }
    @MainActor static func restoreBlocking(_ journal: RecoveryJournal, timeout: TimeInterval) {
        let records = journal.records; guard !records.isEmpty else { return }
        let displays = WindowManager.displayFrames(), group = DispatchGroup(), lock = NSLock(); guard let main = displays.first else { return }
        var done: [ParkedRecord] = []
        for (pid, mine) in Dictionary(grouping: records, by: \.pid) {
            guard let started = ProcessIdentity.started(pid), abs(started - mine[0].started) < 1 else { continue } // sorted out at the next launch
            AXClient.shared.run(pid, in: group) {
                let found = try read(pid, mine[0].bundle, started), steps = Recovery.steps(records: mine, live: found.map(\.window), running: [pid: started], displays: displays, main: main)
                let back = { (window: LiveWindow, frame: CGRect) in found.first { $0.window == window }.flatMap { try? $0.ref.place(frame) }.map { Recovery.inSight($0, displays: displays) } ?? false } // one refusing window does not stop the others
                for step in steps {
                    switch step {
                    case let .restore(record, window, frame): if back(window, frame) { lock.withLock { done.append(record) } }
                    case let .drop(record): lock.withLock { done.append(record) }
                    case .center, .keep: break
                    }
                }
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        lock.withLock { for record in done { try? journal.remove(record) } } // the rest is retried at the next launch
    }
}
