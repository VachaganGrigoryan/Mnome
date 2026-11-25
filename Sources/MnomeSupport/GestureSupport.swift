import CoreGraphics
import Foundation

/// Turns three-finger trackpad frames into a swipe that content can follow, as GNOME's swipe tracker does.
/// Positions are the trackpad's own, 0 to 1, with y going up.
public struct SwipeTracker {
    public enum Axis: Equatable, Sendable { case horizontal, vertical }
    public enum Output: Equatable, Sendable {
        case began(Axis)
        /// Signed: positive is right or up. 1 is a full swipe.
        case update(CGFloat)
        case ended(progress: CGFloat, velocity: CGFloat)
        case cancelled
    }
    public static let fingers = 3, lock: CGFloat = 0.02, span: CGFloat = 0.3
    private var start: CGPoint?, axis: Axis?, last: (progress: CGFloat, time: Double)?, velocity: CGFloat = 0
    public init() {}

    public mutating func feed(count: Int, centroid: CGPoint, time: Double) -> Output? {
        guard count == Self.fingers else {
            defer { self = SwipeTracker() }
            guard axis != nil else { return nil }
            return count > Self.fingers ? .cancelled : .ended(progress: last?.progress ?? 0, velocity: velocity) // fingers lift one by one
        }
        guard let start else { self.start = centroid; return nil }
        let dx = centroid.x - start.x, dy = centroid.y - start.y
        guard let axis else {
            guard max(abs(dx), abs(dy)) >= Self.lock else { return nil }
            axis = abs(dx) >= abs(dy) ? .horizontal : .vertical
            last = (0, time)
            return .began(axis!)
        }
        let progress = (axis == .horizontal ? dx : dy) / Self.span
        if let last, time > last.time { velocity = 0.7 * velocity + 0.3 * (progress - last.progress) / CGFloat(time - last.time) }
        last = (progress, time)
        return .update(progress)
    }
    /// Past half way, or flicked that way.
    public static func commits(progress: CGFloat, velocity: CGFloat) -> Bool { abs(progress) >= 0.5 || (abs(velocity) >= 1 && progress * velocity > 0 && abs(progress) > 0.05) }
}
