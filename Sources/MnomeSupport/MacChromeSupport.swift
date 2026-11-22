import Foundation

public enum PrefValue: Codable, Equatable {
    case bool(Bool), int(Int), double(Double), string(String), absent
}
public protocol PreferenceStore {
    func get(_ domain: String, _ key: String) -> PrefValue
    func set(_ domain: String, _ key: String, _ value: PrefValue)
}
public enum MacElement: String, CaseIterable, Codable {
    case dock, menuBar, desktop, stageManager
    public var title: String {
        switch self {
        case .dock: "Hide Dock"
        case .menuBar: "Hide Menu Bar"
        case .desktop: "Hide Desktop Icons & Widgets"
        case .stageManager: "Disable Stage Manager & Click to Show Desktop"
        }
    }
    public struct Setting { public let domain: String, key: String, hidden: PrefValue }
    public var settings: [Setting] {
        switch self {
        case .dock: [Setting(domain: "com.apple.dock", key: "autohide", hidden: .bool(true)), Setting(domain: "com.apple.dock", key: "autohide-delay", hidden: .double(1000))]
        case .menuBar: [Setting(domain: "NSGlobalDomain", key: "_HIHideMenuBar", hidden: .bool(true))]
        case .desktop: [Setting(domain: "com.apple.finder", key: "CreateDesktop", hidden: .bool(false)),
                        Setting(domain: "com.apple.WindowManager", key: "StandardHideWidgets", hidden: .bool(true)),
                        Setting(domain: "com.apple.WindowManager", key: "StageManagerHideWidgets", hidden: .bool(true))]
        case .stageManager: [Setting(domain: "com.apple.WindowManager", key: "GloballyEnabled", hidden: .bool(false)),
                             Setting(domain: "com.apple.WindowManager", key: "EnableStandardClickToShowDesktop", hidden: .bool(false))]
        }
    }
}
/// Remembers the original value of every preference Mnome changes, so any subset can be put back exactly.
public struct MacChromeSnapshot: Codable, Equatable {
    public var saved: [String: PrefValue] = [:]
    public var hidden: Set<MacElement> = []
    public init() {}
    private static func id(_ s: MacElement.Setting) -> String { "\(s.domain)|\(s.key)" }
    /// Records original values without changing anything, so callers can persist the snapshot before writing.
    public mutating func capture(_ element: MacElement, store: PreferenceStore) {
        for setting in element.settings where saved[Self.id(setting)] == nil { saved[Self.id(setting)] = store.get(setting.domain, setting.key) } // never overwrite the original
    }
    public mutating func hide(_ element: MacElement, store: PreferenceStore) {
        capture(element, store: store)
        for setting in element.settings { store.set(setting.domain, setting.key, setting.hidden) }
        hidden.insert(element)
    }
    /// Elements with anything left to put back, including originals captured just before a crash.
    public var needsRestore: Set<MacElement> { hidden.union(MacElement.allCases.filter { $0.settings.contains { saved[Self.id($0)] != nil } }) }
    /// An original is forgotten only once reading it back proves the write stuck.
    public mutating func restore(_ element: MacElement, store: PreferenceStore) {
        hidden.remove(element)
        let stillUsed = Set(hidden.flatMap { $0.settings.map(Self.id) })
        for setting in element.settings {
            let id = Self.id(setting)
            guard !stillUsed.contains(id), let original = saved[id] else { continue }
            store.set(setting.domain, setting.key, original)
            if store.get(setting.domain, setting.key) == original { saved[id] = nil } else { hidden.insert(element) }
        }
    }
    @discardableResult public mutating func restoreAll(store: PreferenceStore) -> Set<MacElement> {
        let touched = needsRestore
        for element in touched { restore(element, store: store) }
        return touched
    }
}
