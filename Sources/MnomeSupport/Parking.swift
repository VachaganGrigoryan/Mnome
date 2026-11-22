import CoreGraphics

/// Where windows of other workspaces wait: just outside a bottom corner of the main display. Top-left coordinates.
public enum ParkingCorner: Equatable, Sendable { case bottomLeft, bottomRight }
public enum Parking {
    /// macOS keeps about a title bar on screen, so this much of the height stays level with the display.
    static let lip: CGFloat = 64
    /// A corner whose outside no other display covers, or nil when every one would show the window.
    public static func corner(displays: [CGRect], main: CGRect) -> ParkingCorner? {
        let others = displays.filter { $0 != main }
        let free = { (x: CGFloat) in !others.contains { $0.intersects(CGRect(x: x, y: main.maxY - lip, width: main.width, height: main.height)) } }
        return free(main.minX - main.width) ? .bottomLeft : free(main.maxX) ? .bottomRight : nil
    }
    public static func origin(size: CGSize, corner: ParkingCorner, main: CGRect) -> CGPoint {
        CGPoint(x: corner == .bottomLeft ? main.minX - size.width + 1 : main.maxX - 1, y: main.maxY - 1)
    }
    /// Nothing but a sliver is visible. The height left on screen varies by app, the width does not.
    public static func isParked(_ frame: CGRect, displays: [CGRect]) -> Bool {
        displays.allSatisfy { let seen = $0.intersection(frame); return seen.isNull || seen.width <= 4 || seen.height <= 4 }
    }
}
public enum WorkArea {
    /// A screen's usable part between our bar and, when always visible, our dock. Bottom-left coordinates.
    public static func rect(visible: CGRect, bar: CGRect?, dock: CGRect?) -> CGRect {
        let top = bar.map { min(visible.maxY, $0.minY) } ?? visible.maxY, bottom = dock.map { max(visible.minY, $0.maxY) } ?? visible.minY
        return CGRect(x: visible.minX, y: bottom, width: visible.width, height: max(1, top - bottom))
    }
    /// Between bottom-left screen coordinates and top-left Accessibility coordinates; its own inverse.
    public static func flip(_ r: CGRect, primaryHeight: CGFloat) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
}
