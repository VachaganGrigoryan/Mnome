import AppKit
import ApplicationServices

struct WindowReading { let ref: AXUIElement, number: CGWindowID?, frame: CGRect, minimized: Bool, fullscreen: Bool }
struct TrackedWindow { let id: UInt64, pid: pid_t, app: String; var ref: AXUIElement, frame: CGRect, minimized: Bool, fullscreen: Bool }
enum RegistryEvent { case opened(TrackedWindow), closed(UInt64), moved(UInt64, CGRect), minimized(UInt64, Bool), fullscreen(UInt64, Bool), focused(UInt64) }

/// Runs the observers' run loop, so a slow main thread never delays them and they never delay it.
private final class ObserverThread {
    static let shared = ObserverThread()
    private(set) var loop: CFRunLoop!
    private init() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            loop = CFRunLoopGetCurrent()
            var context = CFRunLoopSourceContext(); CFRunLoopAddSource(loop, CFRunLoopSourceCreate(nil, 0, &context), .commonModes) // keeps the loop alive with no observers
            ready.signal(); CFRunLoopRun()
        }
        thread.name = "dev.mnome.ax.observers"; thread.qualityOfService = .userInteractive; thread.start(); ready.wait()
    }
    func perform(_ work: @escaping () -> Void) { CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, work); CFRunLoopWakeUp(loop) }
}
/// One app's observer.
private final class Watcher: @unchecked Sendable {
    let pid: pid_t, deliver: (pid_t, String, AXUIElement) -> Void
    private let lock = NSLock()
    private var observer: AXObserver?, stopped = false
    private let exit: DispatchSourceProcess
    init(_ pid: pid_t, exited: @escaping () -> Void, deliver: @escaping (pid_t, String, AXUIElement) -> Void) {
        self.pid = pid; self.deliver = deliver
        exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main) // macOS announces only some apps
        exit.setEventHandler(handler: exited); exit.activate()
    }
    static let appNotifications = ["AXWindowCreated", "AXFocusedWindowChanged", "AXMainWindowChanged", "AXApplicationActivated"]
    static let windowNotifications = ["AXUIElementDestroyed", "AXWindowMoved", "AXWindowResized", "AXWindowMiniaturized", "AXWindowDeminiaturized"]
    /// On the app's queue. False when the app does not accept observers yet.
    func start() -> Bool {
        var made: AXObserver?
        guard AXObserverCreate(pid, { _, element, name, context in
            guard let context else { return }
            let watcher = Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue()
            watcher.deliver(watcher.pid, name as String, element)
        }, &made) == .success, let made else { return false }
        let app = AXUIElementCreateApplication(pid), me = Unmanaged.passUnretained(self).toOpaque()
        guard Self.appNotifications.filter({ let e = AXObserverAddNotification(made, app, $0 as CFString, me); return e == .success || e == .notificationAlreadyRegistered }).count > 1 else { return false }
        return lock.withLock {
            guard !stopped else { return false } // callbacks only ever arrive through a source, and none was added
            observer = made; CFRunLoopAddSource(ObserverThread.shared.loop, AXObserverGetRunLoopSource(made), .commonModes)
            return true
        }
    }
    func watch(_ window: AXUIElement) { guard let observer = lock.withLock({ observer }) else { return }; for name in Self.windowNotifications { AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque()) } }
    /// The watcher itself outlives the removal, so a callback in flight never meets a freed object.
    func stop() {
        exit.cancel()
        let old = lock.withLock { stopped = true; defer { observer = nil }; return observer }
        if let old { ObserverThread.shared.perform { withExtendedLifetime(self) { CFRunLoopRemoveSource(ObserverThread.shared.loop, AXObserverGetRunLoopSource(old), .commonModes) } } }
    }
}

/// What windows really exist and where they are. Notifications are hints; every fact is read back from the app.
@MainActor final class WindowRegistry {
    private(set) var windows: [UInt64: TrackedWindow] = [:]
    var onEvent: (RegistryEvent) -> Void = { _ in }
    /// Ids from here on are ours, for windows macOS gives no number.
    nonisolated static let firstMadeUpID = UInt64(1) << 40
    /// Limits tracking to one process, for the engine check.
    var only: Set<pid_t>?
    private var watchers: [pid_t: Watcher] = [:], order: [pid_t: [UInt64]] = [:]
    private var rescans: [pid_t: Task<Void, Never>] = [:], refreshes: [UInt64: Task<Void, Never>] = [:]
    private var observers: [NSObjectProtocol] = [], sweep: Timer?, nextID = WindowRegistry.firstMadeUpID, running = false
    private let client = AXClient.shared

    func start() {
        guard !running else { return }; running = true
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ body: @escaping @MainActor (NSRunningApplication?) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication; MainActor.assumeIsolated { body(app) } })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in if let app { self?.attach(app) } }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in if let app { self?.detach(app.processIdentifier) } }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in if let app { self?.attach(app); self?.readFocus(app.processIdentifier) } }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.rescanAll() }
        on(NSWorkspace.didWakeNotification) { [weak self] _ in self?.rescanAll() }
        sweep = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.rescanAll() } }
        sweep?.tolerance = 5
        NSWorkspace.shared.runningApplications.forEach(attach)
    }
    func stop() {
        running = false; sweep?.invalidate(); sweep = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); observers = []
        rescans.values.forEach { $0.cancel() }; refreshes.values.forEach { $0.cancel() }; rescans = [:]; refreshes = [:]
        watchers.values.forEach { $0.stop() }; watchers = [:]
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard running, watchers[pid] == nil, pid != getpid(), only?.contains(pid) ?? (app.activationPolicy == .regular) else { return }
        let watcher = Watcher(pid, exited: { [weak self] in MainActor.assumeIsolated { self?.detach(pid) } }) { [weak self] pid, name, element in DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(pid, name, element) } } }
        watchers[pid] = watcher
        Task {
            // A launching app may refuse observers for a moment.
            for delay in [0.0, 0.3, 1, 3, 8] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard watchers[pid] === watcher else { return }
                if case .success(true) = await client.run(pid, urgent: true, { watcher.start() }) { rescan(pid); readFocus(pid); return }
            }
            if watchers[pid] === watcher { watchers[pid] = nil } // the sweep tries again
        }
    }
    private func detach(_ pid: pid_t) {
        watchers.removeValue(forKey: pid)?.stop(); rescans.removeValue(forKey: pid)?.cancel()
        for id in order[pid] ?? [] where windows[id]?.pid == pid { remove(id) }
        order[pid] = nil; client.forget(pid)
    }
    private func rescanAll() { NSWorkspace.shared.runningApplications.forEach(attach); watchers.keys.forEach { rescan($0) } }

    private func handle(_ pid: pid_t, _ name: String, _ element: AXUIElement) {
        guard watchers[pid] != nil else { return }
        switch name {
        case "AXWindowCreated": rescan(pid)
        case "AXUIElementDestroyed": if let id = id(pid, element) { remove(id) }
        case "AXFocusedWindowChanged", "AXMainWindowChanged", "AXApplicationActivated": rescan(pid); readFocus(pid)
        default: if let id = id(pid, element) { refresh(id) }
        }
    }
    private func id(_ pid: pid_t, _ element: AXUIElement) -> UInt64? { (order[pid] ?? []).first { windows[$0].map { CFEqual($0.ref, element) } ?? false } }

    nonisolated static func read(_ ref: AXUIElement) throws -> WindowReading? {
        let kind = try ref.value("AXSubrole") as? String, minimized = try ref.flag("AXMinimized")
        // A standard window calls itself a dialog while it is minimized; real dialogs have no minimize button.
        guard try kind == "AXStandardWindow" || (minimized && kind == "AXDialog" && ref.value("AXMinimizeButton") != nil) else { return nil }
        return WindowReading(ref: ref, number: Private.windowID(ref), frame: try ref.frame(), minimized: minimized, fullscreen: try ref.flag("AXFullScreen"))
    }
    nonisolated static func list(_ pid: pid_t) throws -> [AXUIElement] { try AXUIElementCreateApplication(pid).value("AXWindows") as? [AXUIElement] ?? [] }

    private func rescan(_ pid: pid_t, after delay: Duration = .milliseconds(50), retries: Int = 4) {
        guard rescans[pid] == nil else { return } // one is about to run
        rescans[pid] = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            rescans[pid] = nil
            // One window failing to answer says nothing about the others.
            guard let watcher = watchers[pid] else { return }
            let result = await client.run(pid) { try Self.list(pid).compactMap { ref -> WindowReading? in do { return try Self.read(ref) } catch AXFailure.hung { throw AXFailure.hung } catch { return nil } } }
            guard watchers[pid] === watcher else { return }
            if case let .success(found) = result { await merge(watcher, found) } else if retries > 0 { rescan(pid, after: .seconds(2), retries: retries - 1) } // or wait for the sweep
        }
    }
    private func merge(_ watcher: Watcher, _ found: [WindowReading]) async {
        let pid = watcher.pid
        var seen: Set<UInt64> = []
        for reading in found {
            guard watchers[pid] === watcher else { return } // the app ended while we were waiting
            if let id = id(pid, reading.ref) ?? reading.number.map(UInt64.init).flatMap({ windows[$0]?.pid == pid ? $0 : nil }) { seen.insert(id); apply(id, reading); continue }
            let id = reading.number.map(UInt64.init) ?? { nextID += 1; return nextID }()
            if windows[id] != nil { remove(id) } // the number was reused; its old owner is gone
            let app = NSRunningApplication(processIdentifier: pid)
            let window = TrackedWindow(id: id, pid: pid, app: app?.bundleIdentifier ?? app?.bundleURL?.path ?? "pid.\(pid)", ref: reading.ref, frame: reading.frame, minimized: reading.minimized, fullscreen: reading.fullscreen)
            windows[id] = window; order[pid, default: []].append(id); seen.insert(id)
            onEvent(.opened(window))
            _ = await client.run(pid) { watcher.watch(reading.ref) }
        }
        // Apps leave out windows on other native Spaces, so only a window that itself says it is gone is removed.
        for id in (order[pid] ?? []) where !seen.contains(id) {
            guard watchers[pid] === watcher, let ref = windows[id]?.ref else { continue }
            if case .failure(.gone) = await client.run(pid, { _ = try ref.value("AXRole") }) { remove(id) }
        }
    }
    private func refresh(_ id: UInt64) {
        guard refreshes[id] == nil, let window = windows[id] else { return }
        refreshes[id] = Task {
            try? await Task.sleep(for: .milliseconds(40)) // coalesces a drag
            guard !Task.isCancelled else { return }
            refreshes[id] = nil
            switch await client.run(window.pid, { try Self.read(window.ref) }) {
            case let .success(reading?): apply(id, reading)
            case .failure(.gone): remove(id)
            default: break // unknown is not gone
            }
        }
    }
    private func apply(_ id: UInt64, _ reading: WindowReading) {
        guard let old = windows[id] else { return }
        windows[id]?.ref = reading.ref; windows[id]?.frame = reading.frame; windows[id]?.minimized = reading.minimized; windows[id]?.fullscreen = reading.fullscreen
        if old.fullscreen != reading.fullscreen { onEvent(.fullscreen(id, reading.fullscreen)) }
        if old.minimized != reading.minimized { onEvent(.minimized(id, reading.minimized)) }
        if old.frame != reading.frame { onEvent(.moved(id, reading.frame)) }
    }
    private func remove(_ id: UInt64) {
        guard let window = windows.removeValue(forKey: id) else { return }
        order[window.pid]?.removeAll { $0 == id }; refreshes.removeValue(forKey: id)?.cancel()
        onEvent(.closed(id))
    }
    private func readFocus(_ pid: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        Task {
            guard case let .success(value) = await client.run(pid, { try AXUIElementCreateApplication(pid).value("AXFocusedWindow") }), let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let id = id(pid, value as! AXUIElement) { onEvent(.focused(id)) }
        }
    }
}
