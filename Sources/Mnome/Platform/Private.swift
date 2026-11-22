import AppKit

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

    // Not in the interface yet: the system check shows whether this macOS still has them.

    private static func symbol<T>(_ library: String, _ name: String, as type: T.Type) -> T? { dlopen(library, RTLD_NOW).flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: type) } }
    private static let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let getBrightness = symbol(displayServices, "DisplayServicesGetBrightness", as: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32).self)
    private static let putBrightness = symbol(displayServices, "DisplayServicesSetBrightness", as: (@convention(c) (UInt32, Float) -> Int32).self)
    /// Nil for a display that does not let macOS set it, as most external ones.
    static func brightness(_ display: CGDirectDisplayID) -> Float? { var value: Float = 0; return getBrightness?(display, &value) == 0 ? value : nil }
    static func setBrightness(_ display: CGDirectDisplayID, _ value: Float) -> Bool { putBrightness?(display, value) == 0 }

    private static let getDark = symbol(skyLight, "SLSGetAppearanceThemeLegacy", as: (@convention(c) () -> Bool).self)
    private static let putDark = symbol(skyLight, "SLSSetAppearanceThemeLegacy", as: (@convention(c) (Bool) -> Void).self)
    static var darkStyle: Bool? { putDark == nil ? nil : getDark?() }
    static func setDarkStyle(_ on: Bool) { putDark?(on) }

    private static let bluetooth = symbol("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", "IOBluetoothPreferenceGetControllerPowerState", as: (@convention(c) () -> Int32).self)
    static var bluetoothOn: Bool? { bluetooth.map { $0() != 0 } }

    private static let nightClient: NSObject? = { dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW); return (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init() }()
    /// The method, only with the signature we know: a different one would corrupt memory.
    private static func night(_ name: String, _ expected: String) -> IMP? {
        guard let nightClient, let method = class_getInstanceMethod(type(of: nightClient), NSSelectorFromString(name)), let encoding = method_getTypeEncoding(method), String(cString: encoding).contains(expected) else { return nil }
        return method_getImplementation(method)
    }
    static var nightLight: (on: Bool, scheduled: Bool)? {
        guard let nightClient, let method = night("getBlueLightStatus:", "BBBi{") else { return nil }
        let status = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 16); defer { status.deallocate() }; memset(status, 0, 512)
        guard unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool).self)(nightClient, NSSelectorFromString("getBlueLightStatus:"), status) else { return nil }
        return (status.load(fromByteOffset: 1, as: UInt8.self) != 0, status.load(fromByteOffset: 4, as: Int32.self) != 0)
    }
    static func setNightLight(_ on: Bool) -> Bool {
        guard let nightClient, let method = night("setEnabled:", "B") else { return false }
        return unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector, Bool) -> Bool).self)(nightClient, NSSelectorFromString("setEnabled:"), on)
    }
}
