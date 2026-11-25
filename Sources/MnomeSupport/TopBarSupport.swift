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
