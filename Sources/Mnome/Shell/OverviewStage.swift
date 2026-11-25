import AppKit
import QuartzCore
import MnomeSupport

/// One display's overview geometry: GNOME's, measured at 1280x800 (`gnome-ref/shell/005`, `017`).
struct OverviewGeometry {
    let id: UInt64, size: CGSize, origin: CGPoint, bar: CGFloat, main: Bool
    var workArea: CGRect { CGRect(x: 0, y: bar, width: size.width, height: size.height - bar) }
    var searchRect: CGRect { CGRect(x: size.width / 2 - 185, y: bar + 12, width: 370, height: 37) }
    let dashHeight: CGFloat = 86
    var dashTop: CGFloat { size.height - 12 - dashHeight }
    var available: CGRect {
        guard main else { return workArea.insetBy(dx: 32, dy: 32) }
        let top = searchRect.maxY + 27
        return CGRect(x: 32, y: top, width: size.width - 64, height: dashTop - 27 - top)
    }
    var box: CGRect { OverviewLayout.box(workArea: workArea.size, in: available) }
    /// In the app grid the workspaces shrink to a row at the top.
    var smallBox: CGRect { OverviewLayout.box(workArea: workArea.size, in: CGRect(x: 0, y: searchRect.maxY + 21, width: size.width, height: size.height * 0.15)) }
    var gridArea: CGRect { CGRect(x: 0, y: smallBox.maxY + 30, width: size.width, height: dashTop - smallBox.maxY - 50) }
    var resultsArea: CGRect { CGRect(x: 0, y: searchRect.maxY + 20, width: size.width, height: dashTop - searchRect.maxY - 40) }
    /// From the engine's global coordinates (top-left of the main display, y down) to this display's.
    func local(_ r: WMRect) -> CGRect { CGRect(x: CGFloat(r.x) - origin.x, y: CGFloat(r.y) - origin.y, width: CGFloat(r.w), height: CGFloat(r.h)) }
}

/// What the overview shows, computed once per change rather than on every frame.
struct OverviewWindow { let id: UInt64, workspace: UInt64, display: UInt64, rect: WMRect, minimized: Bool, sticky: Bool, title: String, appName: String, icon: NSImage? }
struct OverviewSnapshot {
    var workspaces: [UInt64] = [], current: UInt64 = 0, workspacesOn = false, windows: [OverviewWindow] = []
    var currentIndex: Int { workspaces.firstIndex(of: current) ?? 0 }
}

/// GNOME's curves as Core Animation timing.
extension CAMediaTimingFunction {
    static let overview = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94) // ease-out-quad
    static let workspace = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1) // ease-out-cubic
}

/// The workspaces and windows of one display, as layers: Core Animation moves them on the GPU, so the main
/// thread is free during every animation. Hover, clicks, drags and scrolling are hit tests on known rectangles.
@MainActor final class OverviewStageView: NSView {
    let geometry: OverviewGeometry
    weak var controller: OverviewController?
    private(set) var snapshot = OverviewSnapshot()
    private var progress: CGFloat = 0, apps = false
    private let root = CALayer(), background = CALayer(), ring = CALayer(), titleBox = CALayer(), title = CATextLayer(), closeButton = CALayer(), closeMark = CATextLayer()
    private var workspaceLayers: [UInt64: CALayer] = [:], windowLayers: [UInt64: (box: CALayer, image: CALayer, icon: CALayer)] = [:]
    private var wallpaper: CGImage?
    private(set) var windowFrames: [UInt64: CGRect] = [:], workspaceFrames: [UInt64: CGRect] = [:]
    private var hovered: UInt64?, selected: UInt64?
    private var press: (point: CGPoint, window: UInt64?, close: Bool)?, dragging: UInt64?
    private var scrolled: CGFloat = 0, scrollLocked = false, lastWheel = Date.distantPast

    init(geometry: OverviewGeometry) {
        self.geometry = geometry
        super.init(frame: CGRect(origin: .zero, size: geometry.size))
        root.isGeometryFlipped = true; layer = root; wantsLayer = true // layer-hosting: AppKit leaves the sublayers alone
        let scale = NSScreen.screens.first { WindowManager.displayID($0) == geometry.id }?.backingScaleFactor ?? 2
        root.contentsScale = scale
        background.backgroundColor = CGColor(srgbRed: 34 / 255, green: 34 / 255, blue: 38 / 255, alpha: 1); background.frame = bounds; background.opacity = 0
        root.addSublayer(background)
        ring.borderColor = CGColor(gray: 1, alpha: 0.6); ring.borderWidth = 3; ring.cornerRadius = 16; ring.opacity = 0; ring.zPosition = 10
        titleBox.backgroundColor = CGColor(gray: 0.2, alpha: 0.9); titleBox.cornerRadius = 13; titleBox.opacity = 0; titleBox.zPosition = 10
        title.font = NSFont(name: Adwaita.family, size: 13) ?? NSFont.boldSystemFont(ofSize: 13); title.fontSize = 13; title.foregroundColor = .white; title.alignmentMode = .center; title.truncationMode = .end; title.contentsScale = scale
        titleBox.addSublayer(title)
        closeButton.backgroundColor = CGColor(gray: 0.35, alpha: 1); closeButton.cornerRadius = 13; closeButton.bounds = CGRect(x: 0, y: 0, width: 26, height: 26); closeButton.opacity = 0; closeButton.zPosition = 11
        closeMark.string = "✕"; closeMark.fontSize = 12; closeMark.foregroundColor = .white; closeMark.alignmentMode = .center; closeMark.contentsScale = scale; closeMark.frame = CGRect(x: 0, y: 5, width: 26, height: 16)
        closeButton.addSublayer(closeMark)
        for layer in [ring, titleBox, closeButton] { root.addSublayer(layer) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: State in, layers out

    func setWallpaper(_ image: CGImage?) {
        wallpaper = image
        let rect = CGRect(x: 0, y: geometry.bar / geometry.size.height, width: 1, height: 1 - geometry.bar / geometry.size.height) // the part under the bar
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in workspaceLayers.values { layer.contents = image; layer.contentsRect = rect }
        CATransaction.commit()
    }
    func setImages(_ images: [UInt64: CGImage]) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (id, layers) in windowLayers { decorate(layers, image: images[id], window: snapshot.windows.first { $0.id == id }) }
        CATransaction.commit()
    }
    /// The windows and workspaces changed; `slide` when the current workspace did.
    func update(_ snapshot: OverviewSnapshot, images: [UInt64: CGImage], duration: CFTimeInterval, timing: CAMediaTimingFunction = .overview) {
        self.snapshot = snapshot
        let workspaces = geometry.main ? snapshot.workspaces : [snapshot.current], members = mine(snapshot)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for id in workspaceLayers.keys where !workspaces.contains(id) { workspaceLayers.removeValue(forKey: id)?.removeFromSuperlayer() }
        for id in workspaces where workspaceLayers[id] == nil {
            let layer = CALayer(); layer.masksToBounds = true; layer.contentsGravity = .resizeAspectFill; layer.backgroundColor = CGColor(gray: 0.15, alpha: 1)
            layer.contents = wallpaper; layer.contentsRect = CGRect(x: 0, y: geometry.bar / geometry.size.height, width: 1, height: 1 - geometry.bar / geometry.size.height)
            root.insertSublayer(layer, above: background); workspaceLayers[id] = layer
            layer.frame = frame(ofWorkspace: workspaces.firstIndex(of: id)!, among: workspaces, current: snapshot.currentIndex(in: workspaces)) // new ones start where they belong
        }
        for id in windowLayers.keys where !members.contains(where: { $0.id == id }) { let gone = windowLayers.removeValue(forKey: id)!; gone.box.removeFromSuperlayer() }
        for window in members where windowLayers[window.id] == nil {
            let box = CALayer(), image = CALayer(), icon = CALayer()
            image.cornerRadius = 10; image.masksToBounds = true; image.contentsGravity = .resize; image.minificationFilter = .linear
            icon.contentsGravity = .resizeAspect
            box.addSublayer(image); box.addSublayer(icon); root.insertSublayer(box, below: ring)
            windowLayers[window.id] = (box, image, icon)
            decorate(windowLayers[window.id]!, image: images[window.id], window: window)
            if progress > 0 { box.opacity = 0 } // a window that appears while open fades in
            place(window, rect: geometry.local(window.rect), chrome: false)
        }
        CATransaction.commit()
        apply(duration: duration, timing: timing)
    }
    /// 0 is the desktop, 1 the overview.
    func set(progress: CGFloat, apps: Bool, duration: CFTimeInterval, timing: CAMediaTimingFunction = .overview, done: (() -> Void)? = nil) {
        self.progress = progress; self.apps = apps
        if progress < 1 { hovered = nil; selected = nil }
        apply(duration: duration, timing: timing, done: done)
    }
    func select(_ id: UInt64?) { selected = id; showChrome() }

    private func mine(_ snapshot: OverviewSnapshot) -> [OverviewWindow] {
        snapshot.windows.filter { $0.display == geometry.id && (geometry.main ? (snapshot.workspaces.contains($0.workspace) || $0.sticky) : true) }
    }
    private func frame(ofWorkspace index: Int, among ids: [UInt64], current: Int) -> CGRect {
        if apps && geometry.main {
            let small = geometry.smallBox, gap: CGFloat = 24, count = CGFloat(ids.count), start = geometry.size.width / 2 - (count * small.width + (count - 1) * gap) / 2
            return CGRect(x: start + CGFloat(index) * (small.width + gap), y: small.minY, width: small.width, height: small.height)
        }
        let k = CGFloat(index - current), full = OverviewLayout.lerp(geometry.workArea, geometry.box, progress), shifted = full.offsetBy(dx: k * (full.width + 64), dy: 0)
        let scale = k == 0 ? 1 : 1 - 0.06 * progress
        return CGRect(x: shifted.midX - shifted.width * scale / 2, y: shifted.midY - shifted.height * scale / 2, width: shifted.width * scale, height: shifted.height * scale)
    }
    private func apply(duration: CFTimeInterval, timing: CAMediaTimingFunction = .overview, done: (() -> Void)? = nil) {
        let workspaces = geometry.main ? snapshot.workspaces : [snapshot.current], current = snapshot.currentIndex(in: workspaces), members = mine(snapshot), box = geometry.box
        CATransaction.begin(); CATransaction.setAnimationDuration(duration); CATransaction.setAnimationTimingFunction(timing); if duration == 0 { CATransaction.setDisableActions(true) }
        CATransaction.setCompletionBlock(done)
        background.opacity = Float(progress)
        var placed: [UInt64: CGRect] = [:], spaces: [UInt64: CGRect] = [:]
        for (index, id) in workspaces.enumerated() {
            let rect = frame(ofWorkspace: index, among: workspaces, current: current)
            spaces[id] = rect; workspaceLayers[id]?.frame = rect; workspaceLayers[id]?.cornerRadius = (apps ? 12 : 30) * progress
            let ownWindows = members.filter { geometry.main ? ($0.workspace == id || ($0.sticky && index == current)) : true }
            let slots = OverviewLayout.slots(ownWindows.map { ($0.id, geometry.local($0.rect)) }, in: box.insetBy(dx: 24, dy: 24), screenHeight: geometry.size.height)
            let s = rect.width / max(1, box.width)
            for window in ownWindows {
                guard let slot = slots[window.id] else { continue }
                let target = CGRect(x: rect.minX + (slot.minX - box.minX) * s, y: rect.minY + (slot.minY - box.minY) * s, width: slot.width * s, height: slot.height * s)
                let here = index == current && !apps && !window.minimized
                let r = here ? OverviewLayout.lerp(geometry.local(window.rect), target, progress) : target
                placed[window.id] = r
                place(window, rect: r, chrome: !apps && progress > 0)
                windowLayers[window.id]?.box.opacity = window.minimized && index == current && !apps ? Float(progress) : 1
            }
        }
        windowFrames = progress > 0 ? placed : [:]; workspaceFrames = spaces
        CATransaction.commit()
        showChrome()
    }
    private func place(_ window: OverviewWindow, rect: CGRect, chrome: Bool) {
        guard let layers = windowLayers[window.id] else { return }
        layers.box.frame = rect; layers.image.frame = CGRect(origin: .zero, size: rect.size)
        let side: CGFloat = layers.image.contents == nil ? min(64, rect.width * 0.5) : 52
        layers.icon.frame = layers.image.contents == nil ? CGRect(x: rect.width / 2 - side / 2, y: rect.height / 2 - side / 2, width: side, height: side) : CGRect(x: rect.width / 2 - side / 2, y: rect.height - side + 14, width: side, height: side)
        layers.icon.opacity = layers.image.contents == nil || chrome ? 1 : 0
    }
    private func decorate(_ layers: (box: CALayer, image: CALayer, icon: CALayer), image: CGImage?, window: OverviewWindow?) {
        layers.image.contents = image; layers.image.backgroundColor = image == nil ? CGColor(gray: 1, alpha: 0.08) : nil
        layers.icon.contents = window?.icon
        if let window, layers.box.frame.width > 0 { place(window, rect: layers.box.frame, chrome: progress > 0 && !apps) }
    }

    // MARK: Hover chrome

    private func showChrome() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let target = hovered ?? selected
        guard progress > 0, !apps, dragging == nil, let id = target, let rect = windowFrames[id] else { ring.opacity = 0; titleBox.opacity = 0; closeButton.opacity = 0; CATransaction.commit(); return }
        ring.frame = rect.insetBy(dx: -6, dy: -6); ring.opacity = 1
        if hovered == id {
            let name = snapshot.windows.first { $0.id == id }?.title ?? ""
            title.string = name
            let width = min(rect.width, (name as NSString).size(withAttributes: [.font: title.font as? NSFont ?? NSFont.boldSystemFont(ofSize: 13)]).width + 24)
            titleBox.frame = CGRect(x: rect.midX - width / 2, y: rect.maxY + 30, width: width, height: 26); title.frame = CGRect(x: 10, y: 5, width: width - 20, height: 18); titleBox.opacity = 1
            closeButton.position = CGPoint(x: rect.maxX, y: rect.minY); closeButton.opacity = 1
        } else { titleBox.opacity = 0; closeButton.opacity = 0 }
        CATransaction.commit()
    }
    private func window(at point: CGPoint) -> UInt64? {
        guard progress > 0, !apps else { return nil }
        return windowFrames.filter { $0.value.contains(point) }.min { (windowLayers[$0.key]?.box.zPosition ?? 0, $0.value.width * $0.value.height) < (windowLayers[$1.key]?.box.zPosition ?? 0, $1.value.width * $1.value.height) }?.key
    }
    private func onClose(_ point: CGPoint) -> Bool { closeButton.opacity > 0 && hypot(point.x - closeButton.position.x, point.y - closeButton.position.y) <= 15 }

    // MARK: Input

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let now = onClose(point) ? hovered : window(at: point)
        guard now != hovered else { return }
        hovered = now; showChrome()
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; showChrome() }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        press = (point, onClose(point) ? hovered : window(at: point), onClose(point))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let press, let id = press.window, !press.close, let layers = windowLayers[id], let start = windowFrames[id] else { return }
        let point = convert(event.locationInWindow, from: nil)
        if dragging == nil { guard hypot(point.x - press.point.x, point.y - press.point.y) > 5 else { return }; dragging = id; showChrome(); layers.box.zPosition = 5 }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layers.box.frame = start.offsetBy(dx: point.x - press.point.x, dy: point.y - press.point.y)
        CATransaction.commit()
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { press = nil }
        if let id = dragging {
            dragging = nil; windowLayers[id]?.box.zPosition = 0
            let current = snapshot.current
            if let target = workspaceFrames.first(where: { $0.value.contains(point) && $0.key != current })?.key { controller?.move(id, to: target) }
            apply(duration: 0.2); return
        }
        guard let press else { return }
        if press.close, let id = press.window { controller?.closeWindow(id); return }
        if let id = press.window { controller?.choose(id); return }
        if let space = workspaceFrames.first(where: { $0.value.contains(point) })?.key, space != snapshot.current || apps { controller?.enter(space); return }
        controller?.close()
    }
    /// A wheel notch, or a trackpad swipe of 40 points, moves one workspace; in the app grid, one page.
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : -event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            if event.phase == .began { scrolled = 0; scrollLocked = false }
            guard !scrollLocked, event.momentumPhase == [] else { return }
            scrolled += delta
            guard abs(scrolled) > 40 else { return }
            scrollLocked = true; step(scrolled > 0 ? 1 : -1)
        } else {
            guard delta != 0, Date().timeIntervalSince(lastWheel) > 0.25 else { return }
            lastWheel = Date(); step(delta > 0 ? 1 : -1)
        }
    }
    private func step(_ direction: Int) { if apps { controller?.turnPage(direction) } else { controller?.switchWorkspace(direction) } }
}

extension OverviewSnapshot {
    func currentIndex(in ids: [UInt64]) -> Int { ids.firstIndex(of: current) ?? 0 }
}
