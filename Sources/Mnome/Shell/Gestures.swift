import AppKit
import MnomeSupport

/// GNOME's three-finger gestures: up opens the overview, then the app grid; down goes back; sideways switches workspace.
/// Opening the overview and switching workspace follow the fingers; letting go past half way, or with a flick, finishes.
@MainActor final class Gestures {
    private enum Mode {
        case idle, ignored
        /// The overview between closed (0) and open (1); `from` is where it started.
        case overview(from: CGFloat)
        /// One step that happens or not when the fingers let go: the app grid, a workspace inside the overview.
        case step(commit: @MainActor () -> Void, sign: CGFloat)
        /// The slide between workspaces; `ready` once its pictures are in place.
        case workspace(event: WMEvent, direction: CGFloat, ready: Bool)
    }
    private let touch = Multitouch(), overview: OverviewController, slide: WorkspaceSlide, manager: WindowManager
    /// The row of dots, after a workspace switch.
    var popup: @MainActor () -> Void = {}
    private var tracker = SwipeTracker(), mode = Mode.idle, progress: CGFloat = 0, finishing: Task<Void, Never>?, wake: NSObjectProtocol?
    private(set) var trackpads = 0
    static var enabled: Bool { UserDefaults.standard.object(forKey: "trackpadGestures") as? Bool ?? true }

    init(overview: OverviewController, slide: WorkspaceSlide, manager: WindowManager) { self.overview = overview; self.slide = slide; self.manager = manager }

    func start() {
        let latest = Latest()
        trackpads = touch.start { count, centroid, time in
            guard latest.put((count, centroid, time)) else { return } // already on its way: the main thread takes the newest only
            DispatchQueue.main.async { MainActor.assumeIsolated { if let (count, centroid, time) = latest.take() { self.frame(count, centroid, time) } } }
        }
        if !Multitouch.missing.isEmpty { NSLog("Mnome: no trackpad gestures, this macOS lacks %@", Multitouch.missing.joined(separator: ", ")) }
        wake = wake ?? NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.start() } }
    }

    private func frame(_ count: Int, _ centroid: CGPoint, _ time: Double) {
        guard Self.enabled, let out = tracker.feed(count: count, centroid: centroid, time: time) else { return }
        switch out {
        case let .began(axis): self.axis = axis; mode = .idle
        case let .update(p): progress = p; if case .idle = mode { choose(p) }; follow(p)
        case let .ended(p, velocity): end(commit: SwipeTracker.commits(progress: p, velocity: velocity))
        case .cancelled: end(commit: false)
        }
    }
    /// Decided by the first movement: which way, and what is on screen.
    private func choose(_ p: CGFloat) {
        guard finishing == nil, manager.running || overview.isOpen else { mode = .ignored; return }
        let vertical: Bool
        if case .vertical = axis { vertical = true } else { vertical = false }
        if vertical {
            switch (overview.isOpen, overview.showsApps, p > 0) {
            case (false, _, true): mode = .overview(from: 0)
            case (true, false, true): mode = .step(commit: { [overview] in overview.toggle(apps: true) }, sign: 1)
            case (true, false, false): mode = .overview(from: 1)
            case (true, true, false): mode = .step(commit: { [overview] in overview.toggle(apps: false) }, sign: -1)
            default: mode = .ignored
            }
            return
        }
        let direction: CGFloat = p < 0 ? 1 : -1 // fingers to the left bring the next workspace in from the right
        if overview.isOpen {
            mode = overview.showsApps ? .step(commit: { [overview] in overview.turnPage(Int(direction)) }, sign: -direction) : .step(commit: { [overview] in overview.switchWorkspace(Int(direction)) }, sign: -direction)
            return
        }
        let event = WMEvent.stepWorkspace(Int(direction))
        guard let state = manager.state, let target = state.destination(of: event) else { mode = .ignored; return }
        guard slide.available, !slide.sliding else { mode = .step(commit: { [weak self] in self?.send(event) }, sign: -direction); return }
        mode = .workspace(event: event, direction: direction, ready: false)
        Task {
            let ready = await slide.prepare(target)
            guard case let .workspace(event, direction, _) = mode else { if ready { await slide.finish() }; return } // let go meanwhile: `end` waits for this
            mode = ready ? .workspace(event: event, direction: direction, ready: true) : .step(commit: { [weak self] in self?.send(event) }, sign: -direction)
            if ready { slide.set(slideProgress(direction)) }
        }
    }
    private var axis: SwipeTracker.Axis = .horizontal
    private func send(_ event: WMEvent) { manager.send(event); popup() }
    private func slideProgress(_ direction: CGFloat) -> CGFloat { min(1, max(0, -progress * direction)) }

    private func follow(_ p: CGFloat) {
        switch mode {
        case let .overview(from): overview.follow(from + p)
        case let .workspace(_, direction, true): slide.set(slideProgress(direction))
        default: break
        }
    }
    private func end(commit: Bool) {
        let mode = self.mode; self.mode = .idle; tracker = SwipeTracker()
        switch mode {
        case let .overview(from): let onward = commit && (from == 0 ? progress > 0 : progress < 0); overview.settle(open: onward == (from == 0))
        case let .step(action, sign): if commit, progress * sign > 0 { action() }
        case let .workspace(event, direction, ready):
            let done = slideProgress(direction), forward = commit && -progress * direction > 0
            finishing = Task {
                if !ready { self.finishing = nil; if forward { send(event) }; return } // the pictures were not ready in time
                if forward { send(event) }
                await slide.move(to: forward ? 1 : 0, duration: 0.25 * Double(forward ? 1 - done : done) + 0.05)
                await slide.finish(); self.finishing = nil
            }
        case .idle, .ignored: break
        }
    }
}
/// The newest trackpad frame, handed from the framework's thread to the main one. A busy main thread skips frames
/// instead of working through a backlog, so the content never lags behind the fingers.
private final class Latest: @unchecked Sendable {
    private let lock = NSLock(); private var frame: (Int, CGPoint, Double)?
    /// True when nothing was waiting, so the main thread must be asked.
    func put(_ new: (Int, CGPoint, Double)) -> Bool { lock.withLock { defer { frame = new }; return frame == nil } }
    func take() -> (Int, CGPoint, Double)? { lock.withLock { defer { frame = nil }; return frame } }
}
