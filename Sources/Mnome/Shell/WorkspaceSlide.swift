import AppKit
import MnomeSupport
import ScreenCaptureKit

/// GNOME's slide between workspaces, outside the overview. Real windows can only jump, so a cover shows a picture of
/// the workspace being left and one of the workspace to come, slides from one to the other, and goes once the engine
/// has moved the real windows underneath. Workspaces are on the main display only, and so is the slide.
@MainActor final class WorkspaceSlide {
    private let manager: WindowManager, captures: WindowCaptures, wallpapers: Wallpapers
    private var panel: NSPanel?, strip = CALayer(), leaving = CALayer(), coming = CALayer()
    private var display: (id: CGDirectDisplayID, filter: SCContentFilter)?, busy = false, direction: CGFloat = 1
    /// Without Screen Recording there are no pictures to slide, and Reduce Motion asks for none.
    var available: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && CGPreflightScreenCaptureAccess() }
    var sliding: Bool { busy }

    init(manager: WindowManager, captures: WindowCaptures, wallpapers: Wallpapers) { self.manager = manager; self.captures = captures; self.wallpapers = wallpapers }

    /// Slides to where `event` leads, sending it under the cover. Without a slide, it is just sent.
    /// shortcut: a press during a slide switches without one of its own; queue or retarget it if that shows.
    func perform(_ event: WMEvent, sent: () -> Void) async {
        guard available, !busy, let state = manager.state, let target = state.destination(of: event), await prepare(target) else { manager.send(event); sent(); return }
        manager.send(event); sent()
        await move(to: 1, duration: 0.25)
        await finish()
    }

    /// The cover up, with both pictures in place and nothing moved yet. False when there is nothing to show.
    func prepare(_ target: (workspace: UInt64, direction: Int, carried: UInt64?)) async -> Bool {
        guard let screen = NSScreen.screens.first, let state = manager.state else { return false }
        busy = true
        guard let picture = await captureScreen(screen) else { busy = false; return false }
        let size = screen.frame.size, panel = self.panel ?? make()
        panel.setFrame(screen.frame, display: false)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        strip.frame = CGRect(origin: .zero, size: size); strip.sublayerTransform = CATransform3DIdentity
        leaving.frame = strip.bounds; leaving.contents = picture
        coming.frame = strip.bounds.offsetBy(dx: CGFloat(target.direction) * size.width, dy: 0)
        fill(coming, workspace: target.workspace, carried: target.carried, state: state, screen: screen)
        CATransaction.commit()
        direction = CGFloat(target.direction)
        panel.orderFrontRegardless()
        return true
    }
    /// 0 shows the workspace being left, 1 the one to come.
    func move(to progress: CGFloat, duration: TimeInterval) async {
        let x = -direction * progress * strip.bounds.width
        guard duration > 0 else { CATransaction.begin(); CATransaction.setDisableActions(true); strip.sublayerTransform = CATransform3DMakeTranslation(x, 0, 0); CATransaction.commit(); return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            CATransaction.begin(); CATransaction.setAnimationDuration(duration); CATransaction.setAnimationTimingFunction(.workspace)
            CATransaction.setCompletionBlock { done.resume() }
            strip.sublayerTransform = CATransform3DMakeTranslation(x, 0, 0)
            CATransaction.commit()
        }
    }
    /// Once nothing underneath is moving any more; fresh pictures for next time.
    func finish() async {
        _ = await manager.settled(timeout: .milliseconds(500))
        panel?.orderOut(nil); leaving.contents = nil; coming.sublayers = nil; busy = false
        if let state = manager.state { captures.refresh(state.windows.filter { $0.display == state.main && !$0.minimized && !$0.hidden }.map(\.id)) }
    }

    /// The wallpaper and the workspace's windows at their own places, the most recently used on top.
    private func fill(_ layer: CALayer, workspace: UInt64, carried: UInt64?, state: WMState, screen: NSScreen) {
        layer.sublayers = nil
        layer.contents = wallpapers.images[state.main]; layer.contentsGravity = .resizeAspectFill; layer.masksToBounds = true
        let origin = WorkArea.flip(screen.frame, primaryHeight: WindowManager.primaryHeight).origin
        let rank = Dictionary(state.mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let windows = state.windows.filter { $0.display == state.main && !$0.minimized && !$0.hidden && ($0.workspace == workspace || $0.sticky || $0.id == carried) }
            .sorted { (rank[$0.id] ?? .max) > (rank[$1.id] ?? .max) }
        for w in windows {
            let card = CALayer(), frame = w.rect.cgRect.offsetBy(dx: -origin.x, dy: -origin.y)
            card.frame = frame; card.cornerRadius = 10; card.masksToBounds = false
            card.shadowOpacity = 0.35; card.shadowRadius = 14; card.shadowOffset = CGSize(width: 0, height: 4); card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
            if let image = captures.images[w.id] { card.contents = image; card.contentsGravity = .resize }
            else { // never seen yet: a card with its app's icon
                card.backgroundColor = CGColor(srgbRed: 0.18, green: 0.18, blue: 0.2, alpha: 1)
                let icon = CALayer(); icon.frame = CGRect(x: frame.width / 2 - 48, y: frame.height / 2 - 48, width: 96, height: 96)
                icon.contents = IconCache.icon(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == w.app }); icon.contentsGravity = .resizeAspect
                card.addSublayer(icon)
            }
            layer.addSublayer(card)
        }
    }
    /// The first listing of what can be captured takes up to a second: done at launch, not at the first switch.
    func warmUp() { Task { if available, let screen = NSScreen.screens.first { await prepareFilter(screen) } } }
    private func prepareFilter(_ screen: NSScreen) async {
        let id = CGDirectDisplayID(WindowManager.displayID(screen))
        if display?.id != id {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true), let scDisplay = content.displays.first(where: { $0.displayID == id }) else { return }
            let mine = content.applications.filter { $0.processID == getpid() }
            display = (id, SCContentFilter(display: scDisplay, excludingApplications: mine, exceptingWindows: []))
        }
    }
    /// The screen as it is now, without Mnome's own bar and panels.
    private func captureScreen(_ screen: NSScreen) async -> CGImage? {
        await prepareFilter(screen)
        guard let filter = display?.filter, display?.id == CGDirectDisplayID(WindowManager.displayID(screen)) else { return nil }
        let config = SCStreamConfiguration(), scale = screen.backingScaleFactor
        config.width = Int(screen.frame.width * scale); config.height = Int(screen.frame.height * scale); config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: 26) // over every app, under the bar (27)
        panel.isOpaque = true; panel.backgroundColor = .black; panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(); view.wantsLayer = true; view.layer?.isGeometryFlipped = true; view.layer?.masksToBounds = true
        strip.addSublayer(leaving); strip.addSublayer(coming); view.layer?.addSublayer(strip)
        panel.contentView = view; self.panel = panel
        return panel
    }
}
