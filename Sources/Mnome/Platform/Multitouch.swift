import AppKit

/// Raw touches from every trackpad, through the private MultitouchSupport framework (as GNOME reads libinput).
/// Only how many fingers touch and where their centre is are read from each touch record.
final class Multitouch: @unchecked Sendable {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32
    private static let library = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    private static let createList = Private.symbol(library, "MTDeviceCreateList", as: (@convention(c) () -> Unmanaged<CFArray>?).self)
    private static let register = Private.symbol(library, "MTRegisterContactFrameCallback", as: (@convention(c) (UnsafeMutableRawPointer, Callback) -> Void).self)
    private static let unregister = Private.symbol(library, "MTUnregisterContactFrameCallback", as: (@convention(c) (UnsafeMutableRawPointer, Callback) -> Void).self)
    private static let startDevice = Private.symbol(library, "MTDeviceStart", as: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Int32).self)
    private static let stopDevice = Private.symbol(library, "MTDeviceStop", as: (@convention(c) (UnsafeMutableRawPointer) -> Int32).self)
    /// Which calls this macOS lacks; empty when gestures can work.
    static var missing: [String] { [("MTDeviceCreateList", createList == nil), ("MTRegisterContactFrameCallback", register == nil), ("MTUnregisterContactFrameCallback", unregister == nil), ("MTDeviceStart", startDevice == nil), ("MTDeviceStop", stopDevice == nil)].filter(\.1).map(\.0) }
    /// Each touch record is 96 bytes: its state at 20 (3 a new touch, 4 touching) and its position, 0 to 1, at 32.
    private static let stride = 96
    /// On the framework's own thread: the number of fingers down and their centre.
    nonisolated(unsafe) private static var handler: (@Sendable (Int, CGPoint, Double) -> Void)?
    /// Only three-finger frames, and the one that ends them, leave this thread: not every frame of plain pointing.
    nonisolated(unsafe) private static var lastFingers = 0
    private static let callback: Callback = { _, touches, count, time, _ in
        var sum = CGPoint.zero, fingers = 0
        if let touches {
            for i in 0..<Int(max(0, count)) {
                let base = touches + i * Multitouch.stride, state = base.loadUnaligned(fromByteOffset: 20, as: Int32.self)
                guard state == 3 || state == 4 else { continue } // lifting fingers count no more
                sum.x += CGFloat(base.loadUnaligned(fromByteOffset: 32, as: Float.self)); sum.y += CGFloat(base.loadUnaligned(fromByteOffset: 36, as: Float.self)); fingers += 1
            }
        }
        defer { Multitouch.lastFingers = fingers }
        guard fingers == 3 || Multitouch.lastFingers == 3 else { return 0 }
        Multitouch.handler?(fingers, fingers > 0 ? CGPoint(x: sum.x / CGFloat(fingers), y: sum.y / CGFloat(fingers)) : .zero, time)
        return 0
    }
    private var devices: [UnsafeMutableRawPointer] = [], list: CFArray?

    /// The number of trackpads found. shortcut: a trackpad connected later is found only at the next wake or launch.
    @discardableResult func start(_ handler: @escaping @Sendable (Int, CGPoint, Double) -> Void) -> Int {
        stop()
        guard Self.missing.isEmpty, let createList = Self.createList, let register = Self.register, let startDevice = Self.startDevice, let list = createList()?.takeRetainedValue() else { return 0 }
        if Self.handler == nil { Self.handler = handler } // set once: a callback may be reading it on the framework's thread
        self.list = list
        for i in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, i) else { continue }
            let pointer = UnsafeMutableRawPointer(mutating: device)
            register(pointer, Self.callback); _ = startDevice(pointer, 0); devices.append(pointer)
        }
        return devices.count
    }
    func stop() {
        for device in devices { Self.unregister?(device, Self.callback); _ = Self.stopDevice?(device) }
        devices = []; list = nil
    }
}
