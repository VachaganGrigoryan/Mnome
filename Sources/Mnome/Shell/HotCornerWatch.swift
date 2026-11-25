import AppKit
import MnomeSupport

/// Watches the pointer for the hot corner. A tap of its own, listening only, because the corner is over Mnome's
/// own bar, whose events an `NSEvent` global monitor never sees.
@MainActor final class HotCornerWatch {
    var triggered: @MainActor () -> Void = {}
    private var corner = HotCorner(corners: []), tap: CFMachPort?, screens: NSObjectProtocol?
    static var enabled: Bool { UserDefaults.standard.object(forKey: "hotCorner") as? Bool ?? true }

    func start() {
        guard tap == nil else { return }
        let me = Unmanaged.passUnretained(self).toOpaque() // lives as long as the app
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: 1 << CGEventType.mouseMoved.rawValue, callback: { _, type, event, me in
            if let me { let watch = Unmanaged<HotCornerWatch>.fromOpaque(me).takeUnretainedValue(); MainActor.assumeIsolated { watch.moved(type, event) } }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { NSLog("Mnome: no hot corner, the pointer cannot be watched"); return }
        self.tap = tap; CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        updateCorners()
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updateCorners() } }
    }
    private func updateCorners() { corner.corners = HotCorner.corners(displays: WindowManager.displayFrames()) }
    private func moved(_ type: CGEventType, _ event: CGEvent) {
        guard type == .mouseMoved else { if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return } // switched off after a slow moment
        guard Self.enabled else { return }
        let delta = CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
        if corner.feed(at: event.location, delta: delta, time: ProcessInfo.processInfo.systemUptime) { triggered() }
    }
}
