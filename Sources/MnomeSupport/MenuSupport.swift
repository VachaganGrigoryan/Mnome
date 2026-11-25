import Foundation
import CoreGraphics

/// The date menu's month: always six weeks, starting with at least one day of the month before, as GNOME's calendar.
public struct MonthGrid: Equatable {
    public struct Day: Equatable { public let date: Date, number: String, inMonth: Bool, weekend: Bool, today: Bool }
    public let title: String, weekdays: [String], days: [Day]
    public init(month: Date, today: Date, calendar: Calendar = .current) {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
        var lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        if lead == 0 { lead = 7 }
        let start = calendar.date(byAdding: .day, value: -lead, to: first)!, number = NumberFormatter()
        number.locale = calendar.locale; number.minimumIntegerDigits = 2
        days = (0..<42).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            return Day(date: date, number: number.string(from: calendar.component(.day, from: date) as NSNumber) ?? "", inMonth: calendar.isDate(date, equalTo: first, toGranularity: .month), weekend: calendar.isDateInWeekend(date), today: calendar.isDate(date, inSameDayAs: today))
        }
        let names = calendar.veryShortStandaloneWeekdaySymbols
        weekdays = (0..<7).map { names[(calendar.firstWeekday - 1 + $0) % 7] }
        let formatter = DateFormatter(); formatter.locale = calendar.locale; formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(first, equalTo: today, toGranularity: .year) ? "LLLL" : "LLLL y")
        title = formatter.string(from: first)
    }
}

/// What "Run a Command" does with what was typed.
public enum RunCommand: Equatable {
    case nothing, restartShell, command(String)
    public init(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self = text.isEmpty ? .nothing : text == "r" || text == "restart" ? .restartShell : .command(text)
    }
    /// Newest first, no repeats, at most `limit`.
    public static func remember(_ text: String, in history: [String], limit: Int = 20) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return history }
        return Array(([text] + history.filter { $0 != text }).prefix(limit))
    }
}

/// The Mac's volume, brightness and mute keys, as the window server sends them (`NX_SYSDEFINED`, subtype 8).
public enum MediaKey: Equatable {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown
    /// Nil for keys Mnome leaves alone. `down` is false for the release.
    public static func parse(subtype: Int16, data1: Int) -> (key: MediaKey, down: Bool)? {
        guard subtype == 8 else { return nil }
        let code = (data1 & 0xFFFF_0000) >> 16, state = (data1 & 0xFF00) >> 8
        let key: MediaKey? = switch code { case 0: .volumeUp; case 1: .volumeDown; case 7: .mute; case 2: .brightnessUp; case 3: .brightnessDown; default: nil }
        guard let key, state == 0xA || state == 0xB else { return nil }
        return (key, state == 0xA)
    }
    /// The Mac's own sixteen steps, snapped to the grid so repeated presses land on the same levels.
    public static func step(_ level: Double, up: Bool, steps: Double = 16) -> Double {
        let now = (level * steps).rounded(), next = now + (up ? 1 : -1)
        return min(1, max(0, next / steps))
    }
}

/// The power menu's actions. The ones that end the session ask first, with GNOME's 60-second countdown.
public enum SessionAction: String, CaseIterable, Sendable {
    case suspend, restart, powerOff, logOut
    public var menuTitle: String { switch self { case .suspend: "Suspend"; case .restart: "Restart…"; case .powerOff: "Power Off…"; case .logOut: "Log Out…" } }
    public var title: String { switch self { case .suspend: "Suspend"; case .restart: "Restart"; case .powerOff: "Power Off"; case .logOut: "Log Out" } }
    public var asks: Bool { self != .suspend }
    public static let countdown = 60
    public func message(seconds: Int) -> String {
        let s = seconds == 1 ? "1 second" : "\(seconds) seconds"
        switch self {
        case .suspend: return ""
        case .restart: return "The system will restart automatically in \(s)."
        case .powerOff: return "The system will power off automatically in \(s)."
        case .logOut: return "You will be logged out automatically in \(s)."
        }
    }
}

/// Where a shell menu goes. `anchor` is the bar, or the screen, in AppKit coordinates (origin bottom left).
/// `at`: the top-left corner at a point, as a right-click menu. `under`: centred below a menu bar item.
public enum MenuPlace: Equatable, Sendable { case center, trailing, middle, at(CGPoint), under(CGRect) }
public enum ShellMenusPlacement {
    /// Both point-anchored places are kept on the screen.
    public static func origin(_ place: MenuPlace, size: CGSize, anchor: CGRect) -> CGPoint {
        switch place {
        case .center: return CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 8 - size.height)
        case .trailing: return CGPoint(x: anchor.maxX - size.width - 8, y: anchor.minY - 8 - size.height)
        case .middle: return CGPoint(x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2 + anchor.height * 0.1)
        case let .at(p): return CGPoint(x: min(max(anchor.minX, p.x), anchor.maxX - size.width), y: min(max(anchor.minY, p.y - size.height), anchor.maxY - size.height))
        case let .under(item): return CGPoint(x: min(max(anchor.minX + 8, item.midX - size.width / 2), anchor.maxX - size.width - 8), y: item.minY - 4 - size.height)
        }
    }
}

/// The app's menu titles in Mnome's bar, each where the Mac's hidden menu bar has it, so the app's real menu opens
/// right under it. Positions are from the display's left edge. If the first would sit under Activities the row moves
/// right; titles that would reach `end` (the clock) are left out, as the Mac leaves out titles that reach the notch.
public enum AppMenuStrip {
    public static func layout(_ items: [(x: CGFloat, width: CGFloat)], start: CGFloat, end: CGFloat) -> [CGFloat] {
        guard let first = items.first else { return [] }
        let shift = max(0, start - first.x)
        return Array(items.map { $0.x + shift }.enumerated().prefix { $0.element + items[$0.offset].width <= end }.map(\.element))
    }
}
