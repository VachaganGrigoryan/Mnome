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

    nonisolated static var defaultJournal: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mnome/parked.json") }
    init(journal url: URL = WindowManager.defaultJournal) { journal = RecoveryJournal(url: url) }

    func start() {
        guard !running, AXIsProcessTrusted() else { return }
        guard journal.acquire() else { NSLog("Mnome: another copy is managing windows"); return }
        running = true
        updateDisplays()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updateDisplays() } }
        registry.onEvent = { [weak self] in self?.observe($0) }
        Task { if !journal.records.isEmpty { _ = await recover() }; if running { registry.start() } } // before tracking, or parked frames would be taken for real ones
    }
    /// Quitting: the one place that waits, so no window is left in the corner.
    func shutDown() {
        guard running else { return }; running = false
        registry.stop(); chains.values.forEach { $0.cancel() }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        RecoveryRunner.restoreBlocking(journal, timeout: 5)
        journal.release()
    }

    // Displays, with a top-left origin from here on

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    static func displayFrames() -> [CGRect] { NSScreen.screens.map { WorkArea.flip($0.frame, primaryHeight: primaryHeight) } }
    static func displayID(_ screen: NSScreen) -> UInt64 { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint64Value ?? 0 }
    /// Also when our bar or dock appears, moves or goes.
    func updateDisplays() {
        guard running, let main = NSScreen.screens.first else { return } // the first screen has the menu bar
        let displays = NSScreen.screens.map { screen -> WMDisplay in
            let ours = reserved(screen), work = WorkArea.rect(visible: screen.visibleFrame, bar: ours.bar, dock: ours.dock)
            return WMDisplay(id: Self.displayID(screen), frame: WMRect(WorkArea.flip(screen.frame, primaryHeight: Self.primaryHeight)), work: WMRect(WorkArea.flip(work, primaryHeight: Self.primaryHeight)))
        }
        send(.displays(displays, main: Self.displayID(main)))
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
        } catch { NSLog("Mnome: window event refused: %@", String(describing: error)) } // state is unchanged
    }
    var focused: UInt64? { state?.focus }
    /// True when the window is known exactly, so no guessing by title is needed.
    func focus(_ id: UInt64) -> Bool { guard running, state?.window(id) != nil else { return false }; send(.activate(id)); raise(id, after: chains[id]); return true }

    private func observe(_ event: RegistryEvent) {
        switch event {
        case let .opened(w):
            send(.opened(id: w.id, app: w.app, rect: WMRect(w.frame), minimized: w.minimized, fullscreen: w.fullscreen))
            // Left over from an earlier session and only now in reach, for example on another native Space.
            if journal.records.contains(where: { $0.window == w.id && $0.pid == w.pid }) { Task { await RecoveryRunner.restore(journal, only: { $0.window == w.id && $0.pid == w.pid }) } }
        case let .closed(id):
            chains.removeValue(forKey: id)?.cancel(); ledger.forget(id); originals[id] = nil
            if let record = records.removeValue(forKey: id) { try? journal.remove(record) }
            send(.closed(id))
        case let .moved(id, frame): moved(id, frame)
        case let .minimized(id, on): send(.minimized(id, on))
        case let .fullscreen(id, on): send(.fullscreen(id, on))
        case let .focused(id): send(.focused(id))
        }
    }

    private func moved(_ id: UInt64, _ frame: CGRect) {
        guard !ledger.isEcho(id, frame: frame) else { return }
        if records[id] != nil, Parking.isParked(frame, displays: Self.displayFrames()) {
            // Our corner, not the person's choice. If it should be visible, an earlier attempt failed: try again.
            if let rect = state?.window(id)?.rect, ledger.target(id) != .parked { carryOut(id, .shown(exact(id, rect)), revision) }
            return
        }
        ledger.forget(id); send(.moved(id, WMRect(frame)))
    }

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
                switch self.ledger.finished(id, revision: revision, ok: ok, observed: frame) {
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
            var record = ParkedRecord(pid: pid, started: started, bundle: window.app, window: window.id, original: now)
            do { try journal.put(record) } catch { NSLog("Mnome: not parking, the recovery file could not be written: %@", String(describing: error)); return (false, now) }
            records[window.id] = record; originals[window.id] = now
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
        guard case .shown = target, let frame, !Parking.isParked(frame, displays: Self.displayFrames()) else { return }
        originals[id] = nil
        if let record = records.removeValue(forKey: id) { try? journal.remove(record) } // read back where it belongs
    }
    private func gaveUp(_ id: UInt64, _ target: IntentLedger.Target, _ frame: CGRect?) {
        switch target {
        case .parked: send(.sticky(id, true)) // it stays visible on every workspace instead
        case .shown: settled(id, target, frame) // visible, if not exactly where asked
        case .minimized: break
        }
    }
    /// Restored and confirmed first, then focused.
    private func raise(_ id: UInt64, after work: Task<Void, Never>?) {
        Task {
            await work?.value
            guard let window = registry.windows[id], focused == id else { return }
            _ = await client.run(window.pid) { try? window.ref.set("AXMain", kCFBooleanTrue); try? AXUIElementCreateApplication(window.pid).set("AXFrontmost", kCFBooleanTrue); try window.ref.perform("AXRaise") }
            NSRunningApplication(processIdentifier: window.pid)?.activate()
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
    private static func read(_ pid: pid_t, _ bundle: String, _ started: Double) throws -> [Found] {
        try WindowRegistry.list(pid).compactMap { ref in try WindowRegistry.read(ref).map { Found(window: LiveWindow(pid: pid, started: started, bundle: bundle, window: $0.number.map(UInt64.init) ?? 0, frame: $0.frame), ref: ref, plain: !$0.minimized && !$0.fullscreen) } }
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
            case let .drop(record): if !stuck.contains(record.bundle) { try? journal.remove(record) } // its window may still be in the corner
            case let .keep(record): if unreadable.contains(record.pid) { failed += 1 } // otherwise on another Space, or closed
            case let .restore(record, window, frame):
                if await put(window, frame, windows, displays) { try? journal.remove(record) } else { failed += 1 }
            case .center: break
            }
        }
        return failed
    }
    private static func put(_ window: LiveWindow, _ frame: CGRect, _ all: [Found], _ displays: [CGRect]) async -> Bool {
        guard let ref = all.first(where: { $0.window == window })?.ref else { return false }
        for _ in 0..<3 { if case let .success(now) = await AXClient.shared.run(window.pid, urgent: true, { try ref.place(frame) }), !Parking.isParked(now, displays: displays) { return true } }
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
                let back = { (window: LiveWindow, frame: CGRect) in try found.first { $0.window == window }.map { !Parking.isParked(try $0.ref.place(frame), displays: displays) } ?? false }
                for step in steps {
                    switch step {
                    case let .restore(record, window, frame): if try back(window, frame) { lock.withLock { done.append(record) } }
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
