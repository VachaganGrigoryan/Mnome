import Foundation

/// The key that plays GNOME's Super. Left and right differ only in the device flags of an event.
public enum SuperKey: String, CaseIterable, Codable, Sendable {
    case rightCommand, rightOption
    public var keyCode: Int64 { self == .rightCommand ? 54 : 61 }
    public var flag: UInt64 { self == .rightCommand ? 0x10 : 0x40 }
    public var title: String { self == .rightCommand ? "Right Command" : "Right Option" }
    /// Any other modifier held with it, including its own left twin.
    func others(_ flags: UInt64) -> Bool { flags & (KeyFlags.shift | KeyFlags.control | (self == .rightCommand ? KeyFlags.option | KeyFlags.leftCommand : KeyFlags.command | KeyFlags.leftOption)) != 0 }
}
enum KeyFlags { static let shift: UInt64 = 0x2_0000, control: UInt64 = 0x4_0000, option: UInt64 = 0x8_0000, command: UInt64 = 0x10_0000, leftCommand: UInt64 = 0x8, leftOption: UInt64 = 0x20 }

public struct ChordModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let superKey = Self(rawValue: 1), shift = Self(rawValue: 2), option = Self(rawValue: 4), control = Self(rawValue: 8)
}
/// A physical key with modifiers, so shortcuts stay put when the keyboard layout changes.
public struct Chord: Codable, Hashable, Sendable {
    public let key: Int64, modifiers: ChordModifiers
    public init(_ key: Int64, _ modifiers: ChordModifiers) { self.key = key; self.modifiers = modifiers }
    /// Nil with a Command that is not Super: those belong to the Mac.
    public init?(key: Int64, flags: UInt64, superKey: SuperKey) {
        var m: ChordModifiers = []
        let held = flags & superKey.flag != 0
        if held { m.insert(.superKey) }
        if flags & KeyFlags.shift != 0 { m.insert(.shift) }
        if flags & KeyFlags.control != 0 { m.insert(.control) }
        switch superKey {
        case .rightCommand:
            if flags & KeyFlags.leftCommand != 0 || (flags & KeyFlags.command != 0 && !held) { return nil }
            if flags & KeyFlags.option != 0 { m.insert(.option) }
        case .rightOption:
            if flags & KeyFlags.command != 0 { return nil }
            if flags & KeyFlags.leftOption != 0 || (flags & KeyFlags.option != 0 && !held) { m.insert(.option) }
        }
        self.init(key, m)
    }
    static let names: [Int64: String] = [0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Backspace", 53: "Esc", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 115: "Home", 116: "Page Up", 117: "Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"]
    public var label: String {
        var parts: [String] = []
        if modifiers.contains(.superKey) { parts.append("Super") }
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        return (parts + [Self.names[key] ?? "Key \(key)"]).joined(separator: "+")
    }
    /// Without Super, Control or Option it would take a key out of ordinary typing.
    public var isAllowed: Bool { !modifiers.isDisjoint(with: [.superKey, .control, .option]) && Self.names[key] != nil }
}

public enum ShellAction: String, CaseIterable, Codable, Sendable {
    case appGrid, quickSettings, lock
    case tileLeft, tileRight, maximize, restore, minimize, center, close, showDesktop, cycle, cycleBack
    case moveLeft, moveRight, moveUp, moveDown
    case launch1, launch2, launch3, launch4, launch5, launch6, launch7, launch8, launch9
    public var launchIndex: Int? { rawValue.hasPrefix("launch") ? Int(rawValue.dropFirst(6)).map { $0 - 1 } : nil }
    public var title: String {
        switch self {
        case .appGrid: "Show applications"
        case .quickSettings: "Quick settings"
        case .lock: "Lock screen"
        case .tileLeft: "Tile to the left"
        case .tileRight: "Tile to the right"
        case .maximize: "Maximize"
        case .restore: "Restore"
        case .minimize: "Minimize"
        case .center: "Center"
        case .close: "Close window"
        case .showDesktop: "Show desktop"
        case .cycle: "Next window"
        case .cycleBack: "Previous window"
        case .moveLeft: "Move to display on the left"
        case .moveRight: "Move to display on the right"
        case .moveUp: "Move to display above"
        case .moveDown: "Move to display below"
        default: "Open dash app \((launchIndex ?? 0) + 1)"
        }
    }
    public enum Group: String, CaseIterable, Sendable { case shell = "Shell", windows = "Windows", displays = "Displays", dash = "Dash" }
    public var group: Group {
        switch self {
        case .appGrid, .quickSettings, .lock: .shell
        case .moveLeft, .moveRight, .moveUp, .moveDown: .displays
        default: launchIndex == nil ? .windows : .dash
        }
    }
    /// GNOME's own, where it has one. Nil starts unassigned.
    public var standard: Chord? {
        switch self {
        case .appGrid: Chord(0, .superKey)
        case .quickSettings: Chord(1, .superKey)
        case .lock: Chord(37, .superKey)
        case .tileLeft: Chord(123, .superKey)
        case .tileRight: Chord(124, .superKey)
        case .maximize: Chord(126, .superKey)
        case .restore: Chord(125, .superKey)
        case .minimize: Chord(4, .superKey)
        case .center: nil
        case .close: Chord(118, .option)
        case .showDesktop: Chord(2, .superKey)
        case .cycle: Chord(53, .option)
        case .cycleBack: Chord(53, [.option, .shift])
        case .moveLeft: Chord(123, [.superKey, .shift])
        case .moveRight: Chord(124, [.superKey, .shift])
        case .moveUp: Chord(126, [.superKey, .shift])
        case .moveDown: Chord(125, [.superKey, .shift])
        default: launchIndex.map { Chord([18, 19, 20, 21, 23, 22, 26, 28, 25][$0], .superKey) }
        }
    }
}

/// The one list behind the key tap, the Keyboard Shortcuts window and Preferences.
public struct ShortcutTable: Equatable, Sendable {
    public private(set) var chords: [ShellAction: Chord]
    public init() { chords = ShellAction.allCases.reduce(into: [:]) { $0[$1] = $1.standard } }
    public func action(for chord: Chord) -> ShellAction? { chords.first { $0.value == chord }?.key }
    public enum Refusal: Error, Equatable { case notAllowed, taken(ShellAction) }
    public mutating func set(_ action: ShellAction, _ chord: Chord?) -> Refusal? {
        guard let chord else { chords[action] = nil; return nil }
        guard chord.isAllowed else { return .notAllowed }
        if let owner = self.action(for: chord), owner != action { return .taken(owner) }
        chords[action] = chord; return nil
    }
    public mutating func reset() { self = ShortcutTable() }
    /// Only what differs from the standard is stored, so new standards reach everyone.
    public var stored: Data { (try? JSONEncoder().encode(ShellAction.allCases.filter { chords[$0] != $0.standard }.reduce(into: [String: Chord?]()) { $0.updateValue(chords[$1], forKey: $1.rawValue) })) ?? Data() }
    public init(stored data: Data?) {
        self.init()
        guard let data, let changes = try? JSONDecoder().decode([String: Chord?].self, from: data) else { return }
        for name in changes.keys { if let action = ShellAction(rawValue: name) { chords[action] = nil } } // first, so swapped pairs do not collide
        for (name, chord) in changes { if let action = ShellAction(rawValue: name), let chord { _ = set(action, chord) } }
    }
}
