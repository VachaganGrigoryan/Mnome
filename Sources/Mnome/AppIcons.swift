import AppKit
import ApplicationServices
import ScreenCaptureKit

/// The apps' menu bar icons, drawn in Mnome's bar as GNOME's app indicators. macOS 27 draws them in one system process
/// (MenuBarAgent) that tells Accessibility only where each one is: the pictures are cut from a capture of the hidden
/// Mac menu bar, and a click is passed on to the icon there. Needs Screen Recording; the Mac's own Wi-Fi, Sound and
/// other icons are hidden while Mnome's bar is up (`MacElement.statusIcons`), and its clock and Control Center, always
/// the two rightmost, are left out.
@MainActor final class AppIcons {
    struct Icon: Identifiable {
        let id: Int, image: NSImage, frame: CGRect // top-left coordinates, where the Mac's hidden bar has it
        fileprivate let element: AXUIElement, pid: pid_t, pressable: Bool
    }
    private let status: BarStatus
    private var timer: Timer?, observers: [NSObjectProtocol] = [], owners: [pid_t] = [], busy = false
    private var lastPress: (id: Int, at: Date)? // one press per click, however the pointer moves while it is down
    init(status: BarStatus) { self.status = status }

    func start() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.owners = []; self?.refresh() } })
        }
        // shortcut: a capture every 2 seconds, so an icon that changes (a timer, a sync spinner) lags up to that; a stream would follow it live.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        refresh()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); observers = []
        status.appIcons = []
    }

    func press(_ icon: Icon) {
        if let last = lastPress, last.id == icon.id, Date().timeIntervalSince(last.at) < 0.4 { return }
        lastPress = (icon.id, Date())
        let (element, pid, pressable, at) = (icon.element, icon.pid, icon.pressable, CGPoint(x: icon.frame.midX, y: icon.frame.midY))
        Task.detached {
            if pressable { _ = AXUIElementPerformAction(element, "AXPress" as CFString); return }
            for type in [CGEventType.leftMouseDown, .leftMouseUp] { CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)?.postToPid(pid); usleep(50_000) }
        }
    }

    private func refresh() {
        guard !busy, AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { if status.appIcons.count > 0 { status.appIcons = [] }; return }
        busy = true
        // MenuBarAgent is not always among the running apps an app is told of; its bar window always has its number.
        let agent = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]])?.first { $0[kCGWindowOwnerName as String] as? String == "MenuBarAgent" && $0[kCGWindowLayer as String] as? Int == 24 }?[kCGWindowOwnerPID as String] as? pid_t
        let scan = Array(Set((owners.isEmpty ? NSWorkspace.shared.runningApplications.map(\.processIdentifier) : owners) + (agent.map { [$0] } ?? []))), me = getpid()
        Task {
            defer { busy = false }
            let found = await Task.detached { Self.items(scan.filter { $0 != me }) }.value
            owners = Array(Set(found.map(\.pid)))
            let system = found.filter { $0.pid == agent }.sorted { $0.frame.minX < $1.frame.minX }.suffix(2).map(\.frame) // Control Center and the clock
            guard let clock = system.last else { if !status.appIcons.isEmpty { status.appIcons = [] }; return }
            let shown = found.filter { !system.contains($0.frame) }.sorted { $0.frame.minX < $1.frame.minX }
            guard !shown.isEmpty else { if !status.appIcons.isEmpty { status.appIcons = [] }; return }
            guard let strip = await Self.capture(containing: clock) else { return }
            status.appIcons = shown.enumerated().compactMap { i, item in
                Self.cut(item.frame, from: strip, clock: clock).map { Icon(id: i, image: $0, frame: item.frame, element: item.element, pid: item.pid, pressable: item.pressable) }
            }
        }
    }

    private struct Item: @unchecked Sendable { let element: AXUIElement, pid: pid_t, frame: CGRect, pressable: Bool }
    /// Every menu bar icon Accessibility knows of, in the given apps. The 1-second timeout keeps a hung app from holding it up.
    nonisolated private static func items(_ pids: [pid_t]) -> [Item] {
        pids.flatMap { pid -> [Item] in
            guard let bar = try? AXUIElementCreateApplication(pid).value("AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
            return ((try? (bar as! AXUIElement).value("AXChildren")) as? [AXUIElement] ?? []).compactMap { element in
                guard let frame = try? element.frame(), frame.width > 0 else { return nil }
                var actions: CFArray?; AXUIElementCopyActionNames(element, &actions)
                return Item(element: element, pid: pid, frame: frame, pressable: (actions as? [String])?.contains("AXPress") == true)
            }
        }
    }

    /// The hidden Mac menu bar on the display the icons are on, as MenuBarAgent draws it.
    nonisolated private static func capture(containing clock: CGRect) async -> (image: CGImage, frame: CGRect)? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let window = content.windows.first(where: { $0.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent" && $0.windowLayer == 24 && $0.frame.minX <= clock.midX && clock.midX < $0.frame.maxX }) else { return nil }
        // At the display's own scale: a larger picture of a 1x display leaves the bar in its left half.
        let scale = await MainActor.run { NSScreen.screens.first { $0.frame.minX <= clock.midX && clock.midX < $0.frame.maxX }?.backingScaleFactor ?? 2 }
        let config = SCStreamConfiguration(); config.width = Int(window.frame.width * scale); config.height = Int(window.frame.height * scale); config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) else { return nil }
        return (image, window.frame)
    }

    /// One icon out of the strip. The strip is lined up by its right end, the clock's, as the hidden bar does not
    /// always draw the icons where Accessibility says they are.
    private static func cut(_ frame: CGRect, from strip: (image: CGImage, frame: CGRect), clock: CGRect) -> NSImage? {
        let scale = CGFloat(strip.image.width) / strip.frame.width
        guard let right = rightmostInk(strip.image) else { return nil }
        let off = right / scale - (clock.maxX - strip.frame.minX) // where the strip's clock ends, against where Accessibility has it
        let shift = abs(off) < 20 ? 0 : off // the clock's own margin, not a different layout
        let rect = CGRect(x: (frame.minX - strip.frame.minX + shift) * scale, y: 0, width: frame.width * scale, height: CGFloat(strip.image.height)).integral
        guard rect.minX >= 0, let cropped = strip.image.cropping(to: rect) else { return nil }
        let image = NSImage(cgImage: cropped, size: CGSize(width: frame.width, height: strip.frame.height)); image.isTemplate = true
        return image
    }
    /// The last column with anything drawn in it, in pixels.
    private static func rightmostInk(_ image: CGImage) -> CGFloat? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for x in stride(from: width - 1, through: 0, by: -1) { for y in 0..<height where pixels[(y * width + x) * 4 + 3] > 25 { return CGFloat(x + 1) } }
        return nil
    }
}
