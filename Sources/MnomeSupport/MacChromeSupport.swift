import Foundation

public enum PrefValue: Codable, Equatable {
    case bool(Bool), int(Int), double(Double), string(String), absent
}
public protocol PreferenceStore {
    func get(_ domain: String, _ key: String) -> PrefValue
    func set(_ domain: String, _ key: String, _ value: PrefValue)
}
public enum MacElement: String, CaseIterable, Codable {
    case dock, menuBar, desktop, stageManager, missionControl, hotCorners, animations, tiling, statusIcons
    public var title: String {
        switch self {
        case .dock: "Hide Dock"
        case .menuBar: "Hide Menu Bar"
        case .desktop: "Hide Desktop Icons & Widgets"
        case .stageManager: "Disable Stage Manager & Click to Show Desktop"
        case .missionControl: "Disable Mission Control & Its Gestures"
        case .hotCorners: "Disable Hot Corners"
        case .animations: "Turn Off macOS Window Animations"
        case .tiling: "Disable macOS Edge Tiling"
        case .statusIcons: "Hide the Mac's Status Icons (Mnome's Take Their Place)"
        }
    }
    public struct Setting { public let domain: String, key: String, hidden: PrefValue }
    /// Marks a domain's per-Mac layer.
    public static let currentHost = "@currentHost"
    /// The process that reads these settings and must restart to see them.
    public var owner: String? {
        switch self { case .dock, .missionControl, .hotCorners, .animations: "Dock"; case .desktop: "Finder"; case .stageManager, .tiling: "WindowManager"; case .statusIcons: "ControlCenter"; case .menuBar: nil }
    }
    public var settings: [Setting] {
        switch self {
        case .dock: [Setting(domain: "com.apple.dock", key: "autohide", hidden: .bool(true)), Setting(domain: "com.apple.dock", key: "autohide-delay", hidden: .double(1000))]
        case .menuBar: [Setting(domain: "NSGlobalDomain", key: "_HIHideMenuBar", hidden: .bool(true))]
        case .desktop: [Setting(domain: "com.apple.finder", key: "CreateDesktop", hidden: .bool(false)),
                        Setting(domain: "com.apple.WindowManager", key: "StandardHideWidgets", hidden: .bool(true)),
                        Setting(domain: "com.apple.WindowManager", key: "StageManagerHideWidgets", hidden: .bool(true))]
        case .stageManager: [Setting(domain: "com.apple.WindowManager", key: "GloballyEnabled", hidden: .bool(false)),
                             Setting(domain: "com.apple.WindowManager", key: "EnableStandardClickToShowDesktop", hidden: .bool(false))]
        case .missionControl: [Setting(domain: "com.apple.dock", key: "mcx-expose-disabled", hidden: .bool(true))]
            + ["showMissionControlGestureEnabled", "showAppExposeGestureEnabled", "showDesktopGestureEnabled", "showLaunchpadGestureEnabled"].map { Setting(domain: "com.apple.dock", key: $0, hidden: .bool(false)) }
            // The Mac's own swipes (between full-screen apps and Spaces, Mission Control) would run beside Mnome's. 0 is off.
            // Four and five fingers too: on macOS 27 the Mac's Mission Control and Spaces still answer them, whatever mcx-expose-disabled says.
            + ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"].flatMap { domain in ["TrackpadThreeFingerHorizSwipeGesture", "TrackpadThreeFingerVertSwipeGesture", "TrackpadFourFingerHorizSwipeGesture", "TrackpadFourFingerVertSwipeGesture", "TrackpadFourFingerPinchGesture", "TrackpadFiveFingerPinchGesture"].map { Setting(domain: domain, key: $0, hidden: .int(0)) } }
            // The same choice as System Settings keeps it, per Mac; the Dock acts on this one.
            + ["threeFingerHorizSwipeGesture", "threeFingerVertSwipeGesture", "fourFingerHorizSwipeGesture", "fourFingerVertSwipeGesture", "fourFingerPinchSwipeGesture", "fiveFingerPinchSwipeGesture"].map { Setting(domain: "NSGlobalDomain" + MacElement.currentHost, key: "com.apple.trackpad." + $0, hidden: .int(0)) }
        case .hotCorners: ["tl", "tr", "bl", "br"].map { Setting(domain: "com.apple.dock", key: "wvous-\($0)-corner", hidden: .int(1)) } // 1 is "no action"
        case .animations: [Setting(domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", hidden: .bool(false)), Setting(domain: "NSGlobalDomain", key: "NSWindowResizeTime", hidden: .double(0.001)),
                           Setting(domain: "com.apple.dock", key: "launchanim", hidden: .bool(false)), Setting(domain: "com.apple.dock", key: "expose-animation-duration", hidden: .double(0.001))]
        // Mnome's status pill stands in for these. On macOS 27 the per-Mac number decides (8 is "not in the menu bar");
        // "NSStatusItem VisibleCC <name>" is only a copy. The clock and Control Center cannot be hidden: the clock keeps
        // only the time, and Mnome's item shows the date beside it.
        case .statusIcons: ["WiFi", "Bluetooth", "Sound", "Battery", "Display", "ScreenMirroring", "UserSwitcher", "NowPlaying", "FocusModes"].map { Setting(domain: "com.apple.controlcenter" + MacElement.currentHost, key: $0, hidden: .int(8)) }
            + [Setting(domain: "com.apple.menuextra.clock", key: "ShowDate", hidden: .int(2)), Setting(domain: "com.apple.menuextra.clock", key: "ShowDayOfWeek", hidden: .bool(false)), Setting(domain: "com.apple.menuextra.clock", key: "ShowSeconds", hidden: .bool(false))]
        case .tiling: ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTilingOptionAccelerator"].map { Setting(domain: "com.apple.WindowManager", key: $0, hidden: .bool(false)) }
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
