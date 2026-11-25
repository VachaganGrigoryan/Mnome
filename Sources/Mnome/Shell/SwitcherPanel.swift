import AppKit
import ScreenCaptureKit
import SwiftUI
import MnomeSupport

/// GNOME's Alt+Tab: shown after a moment, chosen when the modifier is let go. Windows stay where they are until then.
@MainActor final class SwitcherController: ObservableObject {
    @Published private(set) var switcher: Switcher?
    @Published private(set) var shots: [UInt64: NSImage] = [:]
    var windowManager: WindowManager?
    var endKeys: () -> Void = {}
    private var panel: NSPanel?, show: Task<Void, Never>?, watch: Timer?, bits: CGEventFlags = []
    static var currentOnly: Bool { UserDefaults.standard.bool(forKey: "switcherCurrentWorkspace") }

    func handle(_ key: KeyRouter.SwitcherKey) {
        switch key {
        case let .begin(windows, backwards):
            guard let wm = windowManager, wm.running, let state = wm.state else { endKeys(); return }
            let s = Switcher(state: state, currentOnly: Self.currentOnly, windowsOfFront: windows, backwards: backwards)
            guard !s.isEmpty else { endKeys(); return }
            switcher = s; shots = [:]
            bits = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskAlternate])
            show = Task { try? await Task.sleep(for: .milliseconds(150)); if !Task.isCancelled, switcher != nil { open() } } // a quick press just switches
            // A release can be missed, for example while macOS protects a password field: never keep the keyboard.
            watch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { guard let self, !self.bits.isEmpty, CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: self.bits) else { return }; self.endKeys(); self.finish(choose: true) } }
        case let .next(backwards): switcher?.next(backwards: backwards); capture()
        case .windows: switcher?.showWindows(); capture()
        case .up: switcher?.leaveWindows()
        case .commit: finish(choose: true)
        case .cancel: finish(choose: false)
        }
    }
    func choose(app: Int, window: Int? = nil) { switcher?.select(app, window: window); endKeys(); finish(choose: true) }
    private func finish(choose: Bool) {
        show?.cancel(); watch?.invalidate(); watch = nil; panel?.orderOut(nil); panel = nil
        let chosen = choose ? switcher?.choice : nil; switcher = nil
        if let chosen { _ = windowManager?.focus(chosen) }
    }
    private func open() {
        guard let screen = NSScreen.screens.first else { return }
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu; p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false; p.isReleasedWhenClosed = false; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = NSHostingView(rootView: SwitcherView(controller: self, width: screen.frame.width))
        p.setFrame(screen.frame, display: true); p.orderFrontRegardless(); panel = p; capture()
    }
    /// Pictures of the windows row, as they arrive. Icons until then.
    private func capture() {
        guard panel != nil, let s = switcher, s.window != nil, CGPreflightScreenCaptureAccess() else { return }
        let ids = s.apps[s.selected].windows.filter { shots[$0] == nil }
        guard !ids.isEmpty else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            for id in ids {
                guard let w = content.windows.first(where: { UInt64($0.windowID) == id }) else { continue }
                let config = SCStreamConfiguration(); let scale = 256 / max(1, w.frame.width); config.width = 256; config.height = max(1, Int(w.frame.height * scale)); config.showsCursor = false
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config) { shots[id] = NSImage(cgImage: image, size: .zero) }
            }
        }
    }
    func name(_ id: UInt64) -> (String, NSImage?) {
        let app = windowManager?.registry.windows[id].flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        return (app?.localizedName ?? "Window", app?.icon)
    }
}

/// Values from GNOME's `.switcher-list` and the screenshots `029/032-alt-tab*`.
struct SwitcherView: View {
    @ObservedObject var controller: SwitcherController
    let width: CGFloat
    var body: some View {
        if let s = controller.switcher {
            let icon = max(32, min(96, (width * 0.85 - 24) / CGFloat(s.apps.count) - 24))
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(Array(s.apps.enumerated()), id: \.offset) { i, app in
                        let (name, image) = controller.name(app.windows[0])
                        VStack(spacing: 6) {
                            Group { if let image { Image(nsImage: image).resizable() } else { Image(systemName: "app").resizable() } }.frame(width: icon, height: icon)
                            Text(name).font(.callout).lineLimit(1).frame(maxWidth: icon + 12)
                        }
                        .padding(6).background(i == s.selected ? Color.white.opacity(0.2) : .clear).clipShape(RoundedRectangle(cornerRadius: 16))
                        .contentShape(Rectangle()).onTapGesture { controller.choose(app: i) }
                        .accessibilityLabel(name).accessibilityAddTraits(i == s.selected ? .isSelected : [])
                    }
                }
                if let w = s.window {
                    HStack(spacing: 12) {
                        ForEach(Array(s.apps[s.selected].windows.enumerated()), id: \.offset) { j, id in
                            Group { if let shot = controller.shots[id] { Image(nsImage: shot).resizable().aspectRatio(contentMode: .fit) } else if let image = controller.name(id).1 { Image(nsImage: image).resizable().frame(width: 64, height: 64) } }
                                .frame(width: 256, height: 160).padding(2).background(j == w ? Color.white.opacity(0.2) : .clear).clipShape(RoundedRectangle(cornerRadius: 8))
                                .onTapGesture { controller.choose(app: s.selected, window: j) }
                        }
                    }
                }
            }
            .padding(12).background(Color(red: 0x2e / 255, green: 0x2e / 255, blue: 0x33 / 255)).clipShape(RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 8).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// GNOME's `.workspace-switcher`: dots, the current one larger, for a moment after a keyboard switch.
@MainActor final class WorkspacePopup {
    private var panel: NSPanel?, hide: Task<Void, Never>?
    func show(count: Int, current: Int) {
        guard let screen = NSScreen.screens.first, count > 0 else { return }
        let view = HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in Circle().fill(Color.white.opacity(i == current ? 1 : 0.5)).frame(width: i == current ? 10.7 : 5.3, height: i == current ? 10.7 : 5.3).padding(i == current ? 10.7 : 13.3) }
        }.padding(.horizontal, 18).padding(.vertical, 12).background(Capsule().fill(Color(red: 0x2e / 255, green: 0x2e / 255, blue: 0x33 / 255)))
        let host = NSHostingView(rootView: view), size = host.fittingSize
        let p = panel ?? { let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false); p.level = .popUpMenu; p.backgroundColor = .clear; p.isOpaque = false; p.ignoresMouseEvents = true; p.isReleasedWhenClosed = false; p.collectionBehavior = [.canJoinAllSpaces, .transient]; panel = p; return p }()
        p.contentView = host; p.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 59, width: size.width, height: size.height), display: true) // 4 em above the bottom
        p.alphaValue = 1; p.orderFrontRegardless()
        hide?.cancel(); hide = Task { try? await Task.sleep(for: .milliseconds(750)); guard !Task.isCancelled else { return }; NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 0 } completionHandler: { MainActor.assumeIsolated { if p.alphaValue == 0 { p.orderOut(nil) } } } }
    }
}
