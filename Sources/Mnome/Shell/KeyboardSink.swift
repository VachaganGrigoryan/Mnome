import AppKit

/// Holds the keyboard when no visible window should: typing must never reach a window parked out of sight.
@MainActor final class KeyboardSink {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func keyDown(with event: NSEvent) {}
        override func performKeyEquivalent(with event: NSEvent) -> Bool { true } // nothing here to quit or close
    }
    private lazy var panel: Panel = {
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        p.alphaValue = 0; p.ignoresMouseEvents = true; p.isReleasedWhenClosed = false; p.collectionBehavior = [.canJoinAllSpaces, .transient]
        return p
    }()
    var holds: Bool { panel.isKeyWindow }
    /// Reads back that macOS gave it the keyboard.
    func take() async -> Bool {
        NSApp.activate(); panel.makeKeyAndOrderFront(nil)
        for i in 0..<10 {
            if i == 2 { AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), "AXFrontmost" as CFString, kCFBooleanTrue); panel.makeKeyAndOrderFront(nil) } // macOS may refuse a background app's own request
            if holds && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        NSLog("Mnome: macOS did not give the keyboard to Mnome"); return false
    }
    static func isSink(_ window: NSWindow?) -> Bool { window is Panel }
}
