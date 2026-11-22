import CoreGraphics
import Foundation

/// What each window should look like, and how far we have got. The core holds intentions; this tracks their execution,
/// so late results are dropped, failures retried, and the echo of our own moves is not mistaken for the person's.
public struct IntentLedger {
    public enum Target: Equatable, Sendable { case shown(CGRect), parked, minimized }
    public enum Outcome: Equatable, Sendable { case stale, done, retry, gaveUp }
    private struct Entry { var target: Target, revision: UInt64, attempts = 0, pending = true, settled: CGRect? = nil, quietUntil = Date.distantPast }
    private var entries: [UInt64: Entry] = [:]
    public static let maxAttempts = 3, echo: TimeInterval = 0.5
    public init() {}
    public mutating func intend(_ id: UInt64, _ target: Target, revision: UInt64) { entries[id] = Entry(target: target, revision: revision) }
    public mutating func forget(_ id: UInt64) { entries[id] = nil }
    public func target(_ id: UInt64) -> Target? { entries[id]?.target }
    public func isCurrent(_ id: UInt64, revision: UInt64) -> Bool { entries[id]?.revision == revision }
    /// `ok` is whether the window now is as intended. A frame the app will not take exactly is accepted after the last try.
    public mutating func finished(_ id: UInt64, revision: UInt64, ok: Bool, observed: CGRect?, now: Date = Date()) -> Outcome {
        guard var entry = entries[id], entry.revision == revision else { return .stale }
        defer { entries[id] = entry }
        entry.attempts += 1
        if !ok && entry.attempts < Self.maxAttempts { return .retry }
        entry.pending = false; entry.settled = observed; entry.quietUntil = now.addingTimeInterval(Self.echo)
        return ok ? .done : .gaveUp
    }
    public func isEcho(_ id: UInt64, frame: CGRect, now: Date = Date()) -> Bool {
        guard let entry = entries[id] else { return false }
        if entry.pending || now < entry.quietUntil { return true }
        return entry.settled.map { Self.close($0, frame) } ?? false
    }
    /// We have just put it away, so a report that it has focus is old news and must not bring it back.
    public func isPuttingAway(_ id: UInt64, now: Date = Date()) -> Bool {
        guard let entry = entries[id], entry.pending || now < entry.quietUntil else { return false }
        return entry.target == .parked || entry.target == .minimized
    }
    public static func close(_ a: CGRect, _ b: CGRect, by tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
