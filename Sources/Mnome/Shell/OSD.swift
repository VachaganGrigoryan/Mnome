import AppKit
import SwiftUI

/// GNOME's on-screen display for volume and brightness: a pill near the bottom of every display, gone after 1.5 s.
@MainActor final class OSD {
    private var panels: [NSPanel] = []
    private var hide: Task<Void, Never>?
    func show(icon: String, fallback: String, level: Double?) {
        hide?.cancel()
        let view = OSDView(icon: icon, fallback: fallback, level: level), host = NSHostingView(rootView: view), size = host.fittingSize
        if panels.count != NSScreen.screens.count { panels.forEach { $0.close() }; panels = NSScreen.screens.map { _ in Self.panel() } }
        for (panel, screen) in zip(panels, NSScreen.screens) {
            panel.contentView = NSHostingView(rootView: view)
            panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 58, width: size.width, height: size.height), display: true)
            panel.alphaValue = 1; panel.orderFrontRegardless()
        }
        hide = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500)); guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; self.panels.forEach { $0.animator().alphaValue = 0 } }) { Task { @MainActor in if !Task.isCancelled { self.panels.forEach { $0.orderOut(nil) } } } }
        }
    }
    private static func panel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = NSWindow.Level(rawValue: 26); panel.ignoresMouseEvents = true; panel.hasShadow = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]
        return panel
    }
}
struct OSDView: View {
    let icon: String, fallback: String
    let level: Double?
    var body: some View {
        HStack(spacing: 12) {
            AdwaitaIcon(name: icon, fallback: fallback, size: 32)
            if let level {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(Color.white).frame(width: 160 * min(1, max(0, level)))
                }.frame(width: 160, height: 6)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 18).foregroundStyle(.white)
        .background(Capsule().fill(ShellPalette.switcher)).overlay(Capsule().strokeBorder(Color.white.opacity(0.02), lineWidth: 1))
        .padding(1).environment(\.colorScheme, .dark)
        .accessibilityElement().accessibilityLabel(level.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
    }
}
