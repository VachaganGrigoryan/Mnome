/// Alt+Tab's list and selection. Apps in the order last used, each with its windows in that order.
public struct Switcher: Equatable, Sendable {
    public struct App: Equatable, Sendable { public let app: String; public let windows: [UInt64] }
    public let apps: [App]
    public private(set) var selected = 0
    /// Into one app's windows: the key above Tab, or Down.
    public private(set) var window: Int?

    /// `currentOnly`: what the person can see from here, which includes other displays.
    public init(state: WMState, currentOnly: Bool, windowsOfFront: Bool = false, backwards: Bool = false) {
        let candidates = state.mru.compactMap(state.window).filter { w in !currentOnly || !state.isParked(w.id) && !(w.minimized && state.workspacesOn && w.display == state.main && !w.sticky && w.workspace != state.current) }
        var order: [String] = [], byApp: [String: [UInt64]] = [:]
        for w in candidates { if byApp[w.app] == nil { order.append(w.app) }; byApp[w.app, default: []].append(w.id) }
        // Apps with something to show first, as in GNOME.
        let showing = { (app: String) in byApp[app]!.contains { id in state.window(id).map { !$0.minimized } ?? false } }
        apps = order.filter(showing).map { App(app: $0, windows: byApp[$0]!) } + order.filter { !showing($0) }.map { App(app: $0, windows: byApp[$0]!) }
        if windowsOfFront {
            window = 0; if apps.first.map({ $0.windows.count > 1 }) == true { window = backwards ? apps[0].windows.count - 1 : 1 }
        } else if apps.count > 1 { selected = backwards ? apps.count - 1 : 1 }
    }
    public var isEmpty: Bool { apps.isEmpty }
    public mutating func next(backwards: Bool) {
        guard !apps.isEmpty else { return }
        if let w = window { let n = apps[selected].windows.count; window = (w + (backwards ? n - 1 : 1)) % n; return }
        selected = (selected + (backwards ? apps.count - 1 : 1)) % apps.count
    }
    public mutating func showWindows() { if !apps.isEmpty { window = window.map { ($0 + 1) % apps[selected].windows.count } ?? 0 } }
    public mutating func leaveWindows() { window = nil }
    public mutating func select(_ app: Int, window: Int? = nil) { if apps.indices.contains(app) { selected = app; self.window = window } }
    /// What to bring forward when the modifier is let go.
    public var choice: UInt64? { apps.indices.contains(selected) ? apps[selected].windows[window ?? 0] : nil }
}
