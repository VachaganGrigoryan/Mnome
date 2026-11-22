import ApplicationServices

/// Every undocumented call, looked up at runtime. `nil` means this macOS does not have it and the feature falls back.
enum Private {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindow.self) }
    /// The window server's number for an Accessibility window.
    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let getWindow, getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }
}
