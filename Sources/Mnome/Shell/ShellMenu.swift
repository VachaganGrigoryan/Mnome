import AppKit
import SwiftUI

/// GNOME's panel menus: a rounded box under the bar with no arrow. It takes the keyboard without making Mnome
/// the active app, so closing it leaves the person where they were.
final class ShellMenuPanel: NSPanel {
    var closed: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); closed() }
    override func cancelOperation(_ sender: Any?) { closed() }
}
@MainActor final class ShellMenus {
    private var panel: ShellMenuPanel?
    private var clicks: Any?
    private(set) var open: String?
    var changed: (String?) -> Void = { _ in }
    enum Place { case center, trailing, middle }
    /// `anchor` is the bar (or screen) frame, in AppKit screen coordinates.
    func show(_ id: String, in anchor: CGRect, place: Place, _ content: some View) {
        close()
        let host = NSHostingView(rootView: content.fixedSize()), size = host.fittingSize
        let x: CGFloat = switch place { case .center, .middle: anchor.midX - size.width / 2; case .trailing: anchor.maxX - size.width - 8 }
        let y: CGFloat = place == .middle ? anchor.midY - size.height / 2 + anchor.height * 0.1 : anchor.minY - 8 - size.height
        let panel = ShellMenuPanel(contentRect: CGRect(x: x, y: y, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.level = NSWindow.Level(rawValue: 25); panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.contentView = host; panel.closed = { [weak self] in self?.close() }
        panel.alphaValue = 0; panel.orderFrontRegardless(); panel.makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel; open = id; changed(id)
        clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in Task { @MainActor in self?.close() } } // the desktop and other apps
    }
    func toggle(_ id: String, in anchor: CGRect, place: Place, _ content: @autoclosure () -> some View) { if open == id { close() } else { show(id, in: anchor, place: place, content()) } }
    func close() {
        guard let panel else { return }
        self.panel = nil; panel.closed = {}
        if let clicks { NSEvent.removeMonitor(clicks) }; clicks = nil
        panel.orderOut(nil); open = nil; changed(nil)
    }
}
/// The rounded box every menu draws in, with GNOME's colours and radius.
struct MenuBox<Content: View>: View {
    var radius: CGFloat = 20, padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).background(ShellPalette.popover).clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(ShellPalette.popoverBorder, lineWidth: 1)).padding(1)
    }
}
