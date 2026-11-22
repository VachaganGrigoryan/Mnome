import ApplicationServices

/// Every undocumented call, looked up at runtime. `nil` means this macOS does not have it and the feature falls back.
enum Private {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindow.self) }
    private static let lock = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW).flatMap { dlsym($0, "SACLockScreenImmediate") }.map { unsafeBitCast($0, to: (@convention(c) () -> Int32).self) }
    /// False when this macOS cannot lock this way.
    static func lockScreen() -> Bool { lock.map { _ = $0(); return true } ?? false }
    /// The window server's number for an Accessibility window.
    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let getWindow, getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }
}
