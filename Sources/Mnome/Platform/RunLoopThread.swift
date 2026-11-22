import Foundation

/// A thread with its own run loop, so callbacks never wait for the main thread and never delay it.
final class RunLoopThread: @unchecked Sendable {
    private(set) var loop: CFRunLoop!
    init(_ name: String) {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            loop = CFRunLoopGetCurrent()
            var context = CFRunLoopSourceContext(); CFRunLoopAddSource(loop, CFRunLoopSourceCreate(nil, 0, &context), .commonModes) // keeps the loop alive when nothing else is on it
            ready.signal(); CFRunLoopRun()
        }
        thread.name = name; thread.qualityOfService = .userInteractive; thread.start(); ready.wait()
    }
    /// Never from the thread itself, and never from anything its callbacks wait for.
    func sync<T>(_ work: @escaping () -> T) -> T { let done = DispatchSemaphore(value: 0); var result: T!; perform { result = work(); done.signal() }; done.wait(); return result }
    func perform(_ work: @escaping () -> Void) { CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, work); CFRunLoopWakeUp(loop) }
}
