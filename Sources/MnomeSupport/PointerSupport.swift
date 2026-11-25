import CoreGraphics
import Foundation

/// GNOME's hot corner: pushing the pointer into the top-left corner opens the overview.
/// The pointer stops at the edge but the mouse keeps reporting movement; 100 points of that push within a second count.
public struct HotCorner {
    public static let pressure: CGFloat = 100, span: TimeInterval = 1
    public var corners: [CGPoint]
    private var pushes: [(time: TimeInterval, amount: CGFloat)] = [], armed = true
    public init(corners: [CGPoint]) { self.corners = corners }

    /// Top-left coordinates. True once per visit, when the push is enough.
    public mutating func feed(at point: CGPoint, delta: CGVector, time: TimeInterval) -> Bool {
        guard corners.contains(where: { abs(point.x - $0.x) <= 1 && abs(point.y - $0.y) <= 1 }) else { armed = true; pushes.removeAll(); return false }
        guard armed else { return false }
        let push = max(0, -delta.dx) + max(0, -delta.dy) // up and to the left
        if push > 0 { pushes.append((time, push)) }
        pushes.removeAll { time - $0.time > Self.span }
        guard pushes.reduce(0, { $0 + $1.amount }) >= Self.pressure else { return false }
        armed = false; pushes.removeAll()
        return true
    }
    /// The top-left of each display, unless another display lies beyond it: the pointer would only pass through.
    public static func corners(displays: [CGRect]) -> [CGPoint] {
        displays.compactMap { d in
            let corner = CGPoint(x: d.minX, y: d.minY), beyond = [CGPoint(x: d.minX - 1, y: d.minY), CGPoint(x: d.minX, y: d.minY - 1), CGPoint(x: d.minX - 1, y: d.minY - 1)]
            return displays.contains { $0 != d && beyond.contains(where: $0.contains) } ? nil : corner
        }
    }
}
