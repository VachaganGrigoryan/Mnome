import AppKit
import Combine
import SwiftUI

/// GNOME's desktop: the background, drawn by Mnome behind every app, with a right-click menu. Clicking it changes
/// nothing, so Finder never wakes. Shown while the Mac's desktop is hidden (Preferences → Shell).
@MainActor final class DesktopController {
    private var panels: [NSPanel] = [], watches: [AnyCancellable] = [], observers: [NSObjectProtocol] = [], refresh: Timer?
    private let wallpapers: Wallpapers, menus = ShellMenus()
    var showPreferences: () -> Void = {}
    private(set) var shown = false
    init(wallpapers: Wallpapers) { self.wallpapers = wallpapers }

    func set(shown: Bool) {
        guard shown != self.shown else { return }
        self.shown = shown
        guard shown else { menus.close(); panels.forEach { $0.orderOut(nil) }; panels = []; watches = []; observers.forEach(NotificationCenter.default.removeObserver); observers = []; refresh?.invalidate(); return }
        build()
        watches = [wallpapers.$images.receive(on: DispatchQueue.main).sink { [weak self] images in self?.paint(images) }]
        observers = [NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.build() } }]
        // The Mac says nothing when the wallpaper changes; asking costs a comparison of file names.
        refresh = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.wallpapers.load() } }
    }
    private func build() {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow))); panel.isReleasedWhenClosed = false; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]; panel.isOpaque = true; panel.backgroundColor = .black
            let view = DesktopView(); view.display = WindowManager.displayID(screen)
            view.rightClick = { [weak self, weak panel] point in guard let self, let panel else { return }; self.menu(at: point, on: panel.screen ?? screen) }
            panel.contentView = view; panel.setFrame(screen.frame, display: false); panel.orderBack(nil)
            return panel
        }
        wallpapers.load(); paint(wallpapers.images)
    }
    private func paint(_ images: [UInt64: CGImage]) { for panel in panels { if let view = panel.contentView as? DesktopView { view.layer?.contents = images[view.display] } } }
    private func menu(at point: CGPoint, on screen: NSScreen) {
        func row(_ title: String, _ action: @escaping () -> Void) -> some View { QuickMenuRow(title: title) { [weak self] in self?.menus.close(); action() } }
        let open = { (pane: String) in _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!) }
        menus.show("desktop", in: screen.frame, place: .at(point), MenuBox(radius: 12, padding: 6) {
            VStack(spacing: 0) {
                row("Change Background…") { open("com.apple.Wallpaper-Settings.extension") }
                Divider().padding(.vertical, 4)
                row("Display Settings") { open("com.apple.Displays-Settings.extension") }
                row("Settings") { [weak self] in self?.showPreferences() }
            }.frame(width: 220)
        }.shellTheme(follows: true))
    }
}
final class DesktopView: NSView {
    var display: UInt64 = 0
    var rightClick: (CGPoint) -> Void = { _ in }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.contentsGravity = .resizeAspectFill; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {} // a click on the background changes nothing
    override func rightMouseDown(with event: NSEvent) { rightClick(NSEvent.mouseLocation) }
}
