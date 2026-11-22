import AppKit
import ApplicationServices
import MnomeSupport

enum AXFailure: Error, Equatable { case hung, gone, refused(Int32) }

/// All Accessibility traffic. Each app has one serial queue, so a slow app delays only itself, and one that does not
/// answer is left alone for a while instead of being asked again and again.
final class AXClient: @unchecked Sendable {
    static let shared = AXClient()
    private init() { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1) } // the system-wide element sets it for every element in this process
    private final class Lane: @unchecked Sendable { // touched only on its queue
        let queue: DispatchQueue
        var failures = 0, retryAt = Date.distantPast, enhanced = false, restore: DispatchWorkItem?
        init(_ pid: pid_t) { queue = DispatchQueue(label: "dev.mnome.ax.\(pid)", qos: .userInitiated) }
    }
    private let lock = NSLock()
    private var lanes: [pid_t: Lane] = [:]
    private func lane(_ pid: pid_t) -> Lane { lock.withLock { if let lane = lanes[pid] { return lane }; let lane = Lane(pid); lanes[pid] = lane; return lane } }
    func forget(_ pid: pid_t) { lock.withLock { lanes[pid] = nil } }

    /// `urgent` asks even an app that recently did not answer.
    func run<T>(_ pid: pid_t, urgent: Bool = false, _ work: @escaping () throws -> T) async -> Result<T, AXFailure> {
        let lane = lane(pid)
        return await withCheckedContinuation { continuation in lane.queue.async { continuation.resume(returning: Self.perform(lane, urgent, work)) } }
    }
    /// For quitting, when nothing may be left running: the caller waits on the group.
    func run(_ pid: pid_t, in group: DispatchGroup, _ work: @escaping () throws -> Void) {
        let lane = lane(pid)
        lane.queue.async(group: group) { _ = Self.perform(lane, true, work) }
    }
    private static func perform<T>(_ lane: Lane, _ urgent: Bool, _ work: () throws -> T) -> Result<T, AXFailure> {
        guard urgent || Date() >= lane.retryAt else { return .failure(.hung) }
        do { let value = try work(); lane.failures = 0; lane.retryAt = .distantPast; return .success(value) } catch let failure as AXFailure {
            if failure == .hung { lane.failures += 1; lane.retryAt = Date().addingTimeInterval(min(30, pow(2, Double(lane.failures - 1)))) }
            return .failure(failure)
        } catch { return .failure(.refused(-1)) }
    }

    /// Apps with enhanced Accessibility on animate every move. Call on the app's queue; it is put back once moves stop.
    func pauseEnhancedInterface(_ pid: pid_t) {
        let lane = lane(pid), app = AXUIElementCreateApplication(pid)
        if !lane.enhanced, (try? app.value("AXEnhancedUserInterface") as? Bool) == true { lane.enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) == .success }
        guard lane.enhanced else { return }
        lane.restore?.cancel()
        let item = DispatchWorkItem { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue); lane.enhanced = false }
        lane.restore = item; lane.queue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
}

extension AXUIElement {
    private static func check(_ error: AXError) throws {
        switch error {
        case .success: return
        case .cannotComplete: throw AXFailure.hung
        case .invalidUIElement: throw AXFailure.gone
        default: throw AXFailure.refused(error.rawValue)
        }
    }
    /// Nil when the element has no such attribute; throws when it could not be asked.
    func value(_ name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(self, name as CFString, &value)
        if error == .noValue || error == .attributeUnsupported { return nil }
        try Self.check(error); return value
    }
    func set(_ name: String, _ value: CFTypeRef) throws { try Self.check(AXUIElementSetAttributeValue(self, name as CFString, value)) }
    func perform(_ action: String) throws { try Self.check(AXUIElementPerformAction(self, action as CFString)) }
    func flag(_ name: String) throws -> Bool { try value(name) as? Bool ?? false }
    func frame() throws -> CGRect {
        guard let p = try value("AXPosition"), let s = try value("AXSize"), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { throw AXFailure.refused(0) }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point); AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
    func setPosition(_ point: CGPoint) throws { var point = point; if let v = AXValueCreate(.cgPoint, &point) { try set("AXPosition", v) } }
    /// A fixed-size window refuses; that is an answer, not a failure.
    func setSize(_ size: CGSize) throws {
        var size = size; guard let v = AXValueCreate(.cgSize, &size) else { return }
        do { try set("AXSize", v) } catch AXFailure.refused { return }
    }
    /// Moves and resizes, and returns where the window really ended up. Some apps clamp their size when moved, so it is set twice.
    func place(_ rect: CGRect) throws -> CGRect {
        let start = try frame()
        if IntentLedger.close(start, rect, by: 0.1) { return start }
        if start.size != rect.size { try setSize(rect.size) }
        try setPosition(rect.origin)
        if try frame().size != rect.size { try setSize(rect.size) }
        return try settled { IntentLedger.close($0, rect, by: 0.1) }
    }
    func move(to point: CGPoint, until done: (CGRect) -> Bool) throws -> CGRect { try setPosition(point); return try settled(done) }
    /// Success from macOS says nothing about where a window is, so read it back; apps may take a few frames.
    private func settled(_ done: (CGRect) -> Bool) throws -> CGRect {
        var last = try frame()
        for _ in 0..<6 { if done(last) { usleep(20_000); last = try frame(); if done(last) { break } } else { usleep(30_000); last = try frame() } }
        return last
    }
}

/// A process id alone can be reused.
enum ProcessIdentity {
    static func started(_ pid: pid_t) -> Double? {
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }
}
