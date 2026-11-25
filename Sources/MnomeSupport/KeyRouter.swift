/// Recognises Super pressed and released on its own. Any key, click, scroll or other modifier in between means it was part of something else.
public struct SuperTap: Sendable {
    private var armed = false
    public init() {}
    public mutating func cancel() { armed = false }
    /// True when this change completes a lone tap.
    public mutating func flagsChanged(key: Int64, flags: UInt64, superKey: SuperKey) -> Bool {
        guard key == superKey.keyCode else { armed = false; return false }
        if flags & superKey.flag != 0 { armed = !superKey.others(flags); return false }
        defer { armed = false }
        return armed
    }
}
/// Decides what happens to each key event. Pure, so the tap itself stays trivial.
public struct KeyRouter: Sendable {
    public enum Decision: Equatable, Sendable { case pass, swallow, superTap, run(ShellAction), recorded(Chord), cancelled, switcher(SwitcherKey) }
    /// Alt+Tab, while its modifier is held. Everything else typed meanwhile is the switcher's.
    public enum SwitcherKey: Equatable, Sendable { case begin(windows: Bool, backwards: Bool), next(backwards: Bool), windows, up, commit, cancel }
    public var table = ShortcutTable(), superKey = SuperKey.rightCommand, recording = false
    /// Left Command+Tab opens Mnome's switcher instead of the Mac's.
    public var commandTab = true
    private var tap = SuperTap(), held: Set<Int64> = []
    /// The device bits of the modifier that started it, so the session ends when exactly that key is let go.
    private var session: UInt64?
    public init() {}
    public mutating func pointer() { tap.cancel() }
    /// After macOS switched the tap off, nothing known about held keys can be trusted.
    /// True when a switcher session was open and must be cancelled.
    @discardableResult public mutating func reset() -> Bool { tap.cancel(); held = []; defer { session = nil }; return session != nil }
    public var switching: Bool { session != nil }
    public mutating func flagsChanged(key: Int64, flags: UInt64) -> Decision {
        if let bits = session { if flags & bits == 0 { session = nil; tap.cancel(); return .switcher(.commit) }; return .pass }
        return tap.flagsChanged(key: key, flags: flags, superKey: superKey) && !recording ? .superTap : .pass
    }
    /// Option+Tab and Super+Tab, with the key above Tab for one app's windows. Not in the table: GNOME fixes them too.
    private mutating func startSwitcher(key: Int64, flags: UInt64) -> Decision? {
        guard !recording, key == 48 || key == 50 else { return nil }
        if commandTab, flags & KeyFlags.leftCommand != 0, flags & (KeyFlags.control | KeyFlags.option | superKey.flag) == 0 { // the Mac's Cmd+Tab, taken over
            session = KeyFlags.leftCommand; held.insert(key)
            return .switcher(.begin(windows: key == 50, backwards: flags & KeyFlags.shift != 0))
        }
        guard let chord = Chord(key: key, flags: flags, superKey: superKey) else { return nil }
        let rest = chord.modifiers.subtracting(.shift), bits: UInt64
        if rest == .superKey { bits = superKey.flag } else if rest == .option { bits = flags & (0x20 | 0x40) & ~(superKey == .rightOption ? superKey.flag : 0) } else { return nil }
        guard bits != 0 else { return nil }
        session = bits; held.insert(key)
        return .switcher(.begin(windows: key == 50, backwards: chord.modifiers.contains(.shift)))
    }
    public mutating func keyDown(key: Int64, flags: UInt64, repeated: Bool) -> Decision {
        tap.cancel()
        if session != nil {
            held.insert(key)
            switch key {
            case 48: return .switcher(.next(backwards: flags & KeyFlags.shift != 0))
            case 50: return .switcher(.windows)
            case 123: return .switcher(.next(backwards: true))
            case 124: return .switcher(.next(backwards: false))
            case 125: return repeated ? .swallow : .switcher(.windows)
            case 126: return repeated ? .swallow : .switcher(.up)
            case 53: session = nil; return .switcher(.cancel)
            case 36, 76: session = nil; return .switcher(.commit)
            default: return .swallow
            }
        }
        // Whoever got the press gets the repeats and the release, whatever is held by then.
        if repeated { return held.contains(key) ? .swallow : .pass }
        held.remove(key) // a release we never saw
        if recording {
            held.insert(key)
            guard let chord = Chord(key: key, flags: flags, superKey: superKey) else { return .swallow }
            return chord == Chord(53, []) ? .cancelled : .recorded(chord)
        }
        if !repeated, let started = startSwitcher(key: key, flags: flags) { return started }
        // The Mac keyboard's Mission Control and Launchpad keys, unmodified: GNOME's overview and app grid.
        if flags & (KeyFlags.shift | KeyFlags.control | KeyFlags.option | KeyFlags.command) == 0, let fixed: Decision = key == 160 ? .superTap : key == 131 ? .run(.appGrid) : nil { held.insert(key); return fixed }
        // Ctrl+↑ and Ctrl+↓, the Mac's Mission Control and App Exposé keys: Mnome's overview and app grid instead of the Mac's.
        if let chord = Chord(key: key, flags: flags, superKey: superKey), let fixed: Decision = chord == Chord(126, .control) ? .superTap : chord == Chord(125, .control) ? .run(.appGrid) : nil { held.insert(key); return fixed }
        guard let chord = Chord(key: key, flags: flags, superKey: superKey), let action = table.action(for: chord) else { return .pass }
        held.insert(key)
        return .run(action)
    }
    /// An app must not see the release of a key whose press it never got.
    public mutating func keyUp(key: Int64) -> Decision { held.remove(key) == nil ? .pass : .swallow }
}
