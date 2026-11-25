import Foundation
import CoreGraphics


public enum TopBarGeometry {
    public static func frame(screen: CGRect, visible: CGRect, safeTop: CGFloat, replacesMenuBar: Bool = false, height: CGFloat = 32) -> CGRect {
        if replacesMenuBar { let tall = min(max(height, safeTop), screen.height); return CGRect(x: screen.minX, y: screen.maxY - tall, width: screen.width, height: tall) } // beside the notch
        let top = min(visible.maxY, screen.maxY - max(0, safeTop))
        return CGRect(x: screen.minX, y: max(screen.minY, top - height), width: screen.width, height: min(height, screen.height))
    }
}
public enum StatusText {
    public static func battery(current: Int?, maximum: Int?, charging: Bool) -> String? {
        guard let current, let maximum, maximum > 0 else { return nil }
        let percent = Int((Double(max(0, current)) / Double(maximum) * 100).rounded()).clamped(to: 0...100)
        return "\(charging ? "Charging · " : "")\(percent)%"
    }
    public static func batteryPercent(current: Int?, maximum: Int?) -> Int? {
        guard let current, let maximum, maximum > 0 else { return nil }
        return Int((Double(max(0, current)) / Double(maximum) * 100).rounded()).clamped(to: 0...100)
    }
    public static func batterySymbol(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        let p = percent.clamped(to: 0...100)
        return "battery.\(p == 0 ? 0 : (p + 24) / 25 * 25)"
    }
    public static func network(available: Bool, kind: String?) -> String {
        available ? "\(kind ?? "Network") connected" : "No network connection"
    }
    /// GNOME's "Nov 4  3:15 PM": no weekday, an em space between date and time, each in the locale's order.
    public static func clock(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        func part(_ template: String) -> String {
            let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template); return formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ") // GNOME shows a full space before AM/PM
        }
        return part("MMMd") + "\u{2003}" + part("jm")
    }
    /// The clock's date alone ("Nov 4"), for when the time is shown elsewhere.
    public static func date(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        clock(date, locale: locale, timeZone: timeZone).components(separatedBy: "\u{2003}").first ?? ""
    }
}
/// Adwaita symbolic icon names for the status pill.
public enum StatusIcons {
    public static func battery(percent: Int, charging: Bool) -> String {
        let level = (percent.clamped(to: 0...100) + 5) / 10 * 10
        if charging { return level == 100 ? "battery-level-100-charged-symbolic" : "battery-level-\(level)-charging-symbolic" }
        return "battery-level-\(level)-symbolic"
    }
    /// `rssi` in dBm; nil when unknown, which shows full strength rather than a false weak signal.
    public static func network(available: Bool, wifi: Bool, rssi: Int?) -> String {
        guard available else { return "network-offline-symbolic" }
        guard wifi else { return "network-wired-symbolic" }
        guard let rssi, rssi != 0 else { return "network-wireless-signal-excellent-symbolic" }
        let strength = rssi >= -55 ? "excellent" : rssi >= -67 ? "good" : rssi >= -75 ? "ok" : rssi >= -85 ? "weak" : "none"
        return "network-wireless-signal-\(strength)-symbolic"
    }
    public static func volume(level: Double, muted: Bool) -> String {
        if muted || level <= 0 { return "audio-volume-muted-symbolic" }
        return "audio-volume-\(level < 1.0 / 3 ? "low" : level < 2.0 / 3 ? "medium" : "high")-symbolic"
    }
}
/// The Activities button: one dot per workspace, the current one a wide pill (measured from GNOME's bar).
public enum WorkspaceDots {
    public static let active = CGSize(width: 29, height: 8), inactive = CGSize(width: 6, height: 6), spacing: CGFloat = 6
    /// Whether each dot is the current workspace; a single pill when workspaces are off.
    public static func dots(count: Int, current: Int, on: Bool) -> [Bool] {
        guard on, count > 1 else { return [true] }
        let current = current.clamped(to: 0...(count - 1))
        return (0..<count).map { $0 == current }
    }
    public static func label(count: Int, current: Int, on: Bool) -> String {
        guard on, count > 1 else { return "Activities" }
        return "Activities, workspace \(current.clamped(to: 0...(count - 1)) + 1) of \(count)"
    }
}
private extension Int { func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) } }

/// What Mnome's bar shows where, as the person arranged it: Command-drag in the bar, or Preferences → Shell → Top Bar.
/// The app's menus always follow the left zone.
public enum BarItem: String, Codable, CaseIterable, Sendable { case activities, clock, status, appIcons }
public struct BarLayout: Codable, Equatable, Sendable {
    public enum Zone: String, CaseIterable, Sendable { case left, center, right }
    public var left: [BarItem], center: [BarItem], right: [BarItem]
    public init(left: [BarItem], center: [BarItem], right: [BarItem]) { self.left = left; self.center = center; self.right = right }
    /// GNOME's: Activities, the clock in the middle, the indicators and the status pill on the right.
    public static let gnome = BarLayout(left: [.activities], center: [.clock], right: [.appIcons, .status])
    public subscript(zone: Zone) -> [BarItem] {
        get { switch zone { case .left: left; case .center: center; case .right: right } }
        set { switch zone { case .left: left = newValue; case .center: center = newValue; case .right: right = newValue } }
    }
    /// A saved layout, or GNOME's when it is missing or does not hold each item exactly once.
    public init(data: Data?) {
        let saved = data.flatMap { try? JSONDecoder().decode(BarLayout.self, from: $0) }
        self = saved.map { ($0.left + $0.center + $0.right).map(\.rawValue).sorted() == BarItem.allCases.map(\.rawValue).sorted() } == true ? saved! : .gnome
    }
    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public var clockOnRight: Bool { right.contains(.clock) }
    public func moving(_ item: BarItem, to zone: Zone, at index: Int) -> BarLayout {
        var layout = self
        for z in Zone.allCases { layout[z].removeAll { $0 == item } }
        layout[zone].insert(item, at: min(max(0, index), layout[zone].count)); return layout
    }
    /// Where a dragged item lands: the third of the bar under `x`, and the slot there whose middle is past `x`.
    public func dropping(_ item: BarItem, at x: CGFloat, width: CGFloat, widths: [BarItem: CGFloat]) -> BarLayout {
        let zone: Zone = x < width / 3 ? .left : x > width * 2 / 3 ? .right : .center
        let others = self[zone].filter { $0 != item }, sizes = others.map { widths[$0] ?? 0 }, total = sizes.reduce(0, +)
        var start: CGFloat = switch zone { case .left: 0; case .center: (width - total) / 2; case .right: width - total }
        var index = 0
        for size in sizes { if x > start + size / 2 { index += 1 }; start += size }
        return moving(item, to: zone, at: index)
    }
}
