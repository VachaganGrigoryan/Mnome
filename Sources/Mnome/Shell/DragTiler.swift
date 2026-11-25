import AppKit
import MnomeSupport

/// GNOME's edge tiling: drag a window to an edge or corner to tile it, to the top to maximize it, away to get its size back.
/// Dragging the edge two tiles share resizes both.
@MainActor final class DragTiler {
    private let manager: WindowManager
    private let preview = TilePreviewPanel()
    private var monitor: Any?
    private var down: CGPoint?, window: UInt64?, zone: WMSnap?, border: WMBorder?, lastBorder = Date.distantPast, lastZone = Date.distantPast
    private var dropped: (id: UInt64, until: Date)? // the drop's own late move report, which would undo the tile
    static var enabled: Bool { UserDefaults.standard.object(forKey: "edgeTiling") as? Bool ?? true }

    init(_ manager: WindowManager) {
        self.manager = manager
        manager.userMoved = { [weak self] in self?.moved($0, $1) ?? false }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type; MainActor.assumeIsolated { self?.pointer(type) }
        }
    }

    /// Top-left coordinates, as the core's.
    private static var pointer: CGPoint { let p = NSEvent.mouseLocation; return CGPoint(x: p.x, y: WindowManager.primaryHeight - p.y) }

    private func pointer(_ type: NSEvent.EventType) {
        guard Self.enabled, manager.running else { return reset() }
        let p = Self.pointer
        switch type {
        case .leftMouseDown:
            reset(); down = p
            border = manager.hit(p)?.border.flatMap { onTileEdge($0, p) ? $0 : nil }
        case .leftMouseDragged:
            if let border, Date().timeIntervalSince(lastBorder) > 1.0 / 60 { lastBorder = Date(); manager.send(.dragBorder(border, coordinate: Int((border.vertical ? p.x : p.y).rounded()))) }
            else if window != nil, Date().timeIntervalSince(lastZone) > 1.0 / 30 { lastZone = Date(); track(p) } // asking the core costs a copy of all its state
        case .leftMouseUp:
            if let border { manager.send(.dragBorder(border, coordinate: Int((border.vertical ? p.x : p.y).rounded()))) }
            else if let window { track(p) }
            if border == nil, let window, let zone { dropped = (window, Date().addingTimeInterval(0.4)); manager.send(.snap(window, zone)) }
            reset()
        default: break
        }
    }
    private func reset() { down = nil; window = nil; zone = nil; border = nil; preview.hide() }

    /// Only a press on the edge of a tile starts a border drag: elsewhere along the line is another window or the desktop.
    private func onTileEdge(_ border: WMBorder, _ p: CGPoint) -> Bool {
        guard let state = manager.state else { return false }
        return state.windows.contains { w in
            guard w.placement == .tiled, w.display == border.display, state.isShown(w.id) else { return false }
            let r = w.rect.cgRect
            return border.vertical ? (r.minY...r.maxY).contains(p.y) && min(abs(p.x - r.minX), abs(p.x - r.maxX)) <= 6
                                   : (r.minX...r.maxX).contains(p.x) && min(abs(p.y - r.minY), abs(p.y - r.maxY)) <= 6
        }
    }

    /// From the window manager, for each move the person makes. True when the core should not hear of it.
    private func moved(_ id: UInt64, _ frame: CGRect) -> Bool {
        if let dropped, dropped.id == id { if Date() < dropped.until { return true }; self.dropped = nil }
        guard Self.enabled, let down, NSEvent.pressedMouseButtons & 1 != 0, let state = manager.state, let w = state.window(id) else { return false }
        if let border { return w.placement == .tiled && w.display == border.display } // ours to place while the border moves
        guard window == nil else { return false }
        // Moved, not resized, and held where it was pressed: the title bar is being dragged.
        guard abs(frame.width - CGFloat(w.rect.w)) < 2, abs(frame.height - CGFloat(w.rect.h)) < 2, w.rect.cgRect.insetBy(dx: -4, dy: -4).contains(down) else { return false }
        window = id
        guard w.placement == .tiled || w.placement == .maximized else { return false }
        let p = Self.pointer
        manager.send(.dragAway(id, x: Int(p.x.rounded()), y: Int(p.y.rounded()), header: Int((down.y - CGFloat(w.rect.y)).rounded())))
        return true
    }

    private func track(_ p: CGPoint) {
        zone = manager.hit(p)?.snap
        guard let zone, let window, let display = manager.displays.first(where: { $0.frame.cgRect.contains(p) }) else { return preview.hide() }
        preview.show(TilePreview.rect(for: zone, work: display.work).cgRect, below: window)
    }
}

/// The accent-coloured rectangle that shows where a dropped window will go.
@MainActor final class TilePreviewPanel {
    private var panel: NSPanel?
    func show(_ rect: CGRect, below window: UInt64) {
        let frame = CGRect(x: rect.minX, y: WindowManager.primaryHeight - rect.maxY, width: rect.width, height: rect.height).insetBy(dx: 4, dy: 4)
        let panel = self.panel ?? make()
        if !panel.isVisible || panel.alphaValue == 0 {
            panel.setFrame(frame, display: false); panel.alphaValue = 0
            // Under the dragged window, as in GNOME. A made-up number has no place in the window server's order.
            if window < WindowRegistry.firstMadeUpID { panel.level = .normal; panel.order(.below, relativeTo: Int(window)) } else { panel.level = .floating; panel.orderFrontRegardless() }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15; context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94) // ease-out-quad
            panel.animator().setFrame(frame, display: true); panel.animator().alphaValue = 1
        }
    }
    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }, completionHandler: { MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } } })
    }
    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let view = NSView(); view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor; view.layer?.cornerRadius = 12
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor; view.layer?.borderWidth = 1
        panel.contentView = view; self.panel = panel
        return panel
    }
}
