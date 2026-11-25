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
    public static func clock(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d jm")
        return formatter.string(from: date)
    }
}
private extension Int { func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) } }
