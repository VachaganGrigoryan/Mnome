import Foundation

/// Decides about a report that a parked window has the keyboard: the person chose it (Dock, Cmd+Tab, a link), so
/// their workspace follows, or macOS picked it after something closed, hid or quit, so it is undone.
public enum FocusGate {
    public enum Verdict: Equatable, Sendable { case follow, refuse, ignore }
    /// The window that had the keyboard before, as it is now. `nothing` when Mnome held it, so only the person can have chosen.
    public enum Before: Equatable, Sendable { case nothing, shown, gone }
    public struct Facts: Sendable {
        public var before: Before = .nothing, stillFocused = true, ours = false, desktopClick: TimeInterval = .infinity, finder = false
        public init(before: Before = .nothing, stillFocused: Bool = true, ours: Bool = false, desktopClick: TimeInterval = .infinity, finder: Bool = false) {
            self.before = before; self.stillFocused = stillFocused; self.ours = ours; self.desktopClick = desktopClick; self.finder = finder
        }
    }
    /// `ours`: a focus command of ours is still being carried out, or we just put this window away.
    public static func verdict(_ f: Facts) -> Verdict {
        if f.ours || !f.stillFocused { return .ignore }
        if f.finder && f.desktopClick < 0.5 { return .refuse } // a click on the desktop wakes Finder and its last window
        return f.before == .gone ? .refuse : .follow
    }
}
