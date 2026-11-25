import CoreGraphics
import Foundation

/// A window we are about to park or have parked. Written before it moves, deleted only once it is back.
public struct ParkedRecord: Codable, Equatable, Sendable {
    public let pid: Int32, started: Double, bundle: String, window: UInt64, original: CGRect
    public var parked: CGRect? // nil until the move is confirmed
    public init(pid: Int32, started: Double, bundle: String, window: UInt64, original: CGRect, parked: CGRect? = nil) { self.pid = pid; self.started = started; self.bundle = bundle; self.window = window; self.original = original; self.parked = parked }
    public func sameWindow(_ other: ParkedRecord) -> Bool { pid == other.pid && started == other.started && window == other.window }
}
public struct LiveWindow: Equatable, Sendable {
    public let pid: Int32, started: Double, bundle: String, window: UInt64, frame: CGRect
    public init(pid: Int32, started: Double, bundle: String, window: UInt64, frame: CGRect) { self.pid = pid; self.started = started; self.bundle = bundle; self.window = window; self.frame = frame }
}
public enum RecoveryStep: Equatable, Sendable {
    case restore(ParkedRecord, LiveWindow, CGRect)
    case center(LiveWindow, CGRect)     // parked, but not a window we can name
    case drop(ParkedRecord)             // gone, or already visible
    case keep(ParkedRecord)             // out of reach for now; try again later
}
public enum Recovery {
    /// Only windows that are really parked are moved, so one the person already rescued stays where it is.
    /// `running` holds the start time of every process that still exists: a missing window of a running app may
    /// only be on another native Space, so its record is kept until the app ends.
    public static func steps(records: [ParkedRecord], live: [LiveWindow], running: [Int32: Double], displays: [CGRect], main: CGRect) -> [RecoveryStep] {
        var steps: [RecoveryStep] = [], named: [LiveWindow] = [], ended: [ParkedRecord] = []
        for record in records {
            guard let started = running[record.pid], abs(started - record.started) < 1 else { ended.append(record); steps.append(.drop(record)); continue }
            guard let window = live.first(where: { $0.pid == record.pid && abs($0.started - record.started) < 1 && $0.window == record.window }) else { steps.append(.keep(record)); continue }
            named.append(window)
            steps.append(inSight(window.frame, displays: displays) ? .drop(record) : .restore(record, window, onScreen(record.original, displays: displays, main: main)))
        }
        // An app that restarted may reopen a window exactly where it was parked. Nothing else of that app is touched.
        for window in live where !named.contains(window) && Parking.isParked(window.frame, displays: displays) && ended.contains(where: { $0.bundle == window.bundle && ($0.parked.map { IntentLedger.close($0, window.frame, by: 4) } ?? false) }) { steps.append(.center(window, centered(window.frame.size, in: main))) }
        return steps
    }
    /// Enough of it to see and grab. Anything less never counts as returned.
    public static func inSight(_ frame: CGRect, displays: [CGRect]) -> Bool { displays.contains { let seen = $0.intersection(frame); return !seen.isNull && seen.width >= 40 && seen.height >= 20 } }
    /// The frame, unless its display is gone and it would be out of sight.
    public static func onScreen(_ frame: CGRect, displays: [CGRect], main: CGRect) -> CGRect {
        inSight(frame, displays: displays) ? frame : centered(frame.size, in: main)
    }
    public static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        let w = min(size.width, area.width), h = min(size.height, area.height)
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
    }
}
/// The records on disk. Every change is one atomic write.
public final class RecoveryJournal {
    public let url: URL
    public private(set) var records: [ParkedRecord]
    private var lock: Int32 = -1
    /// An unreadable file is kept aside rather than overwritten.
    public init(url: URL) {
        self.url = url; records = []
        guard let data = try? Data(contentsOf: url) else { return }
        do { records = try JSONDecoder().decode([ParkedRecord].self, from: data) } catch {
            let aside = url.appendingPathExtension("unreadable"); try? FileManager.default.removeItem(at: aside); try? FileManager.default.moveItem(at: url, to: aside)
        }
    }
    /// One owner at a time, or two copies would erase each other's records. Let go when the process ends, however it ends.
    public func acquire() -> Bool {
        if lock >= 0 { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lock = open(url.path + ".lock", O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return false }
        if let data = try? Data(contentsOf: url), let fresh = try? JSONDecoder().decode([ParkedRecord].self, from: data) { records = fresh } // the last owner may have written since
        return true
    }
    public func release() { if lock >= 0 { close(lock); lock = -1 } }
    deinit { release() }
    /// Throws when the record is not safely on disk: the window must then not be moved.
    public func put(_ record: ParkedRecord) throws { try write(records.filter { !$0.sameWindow(record) } + [record]) }
    public func remove(_ record: ParkedRecord) throws { try write(records.filter { !$0.sameWindow(record) }) }
    private func write(_ next: [ParkedRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        records = next
    }
}
