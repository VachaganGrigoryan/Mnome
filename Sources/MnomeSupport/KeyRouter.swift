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
    public enum Decision: Equatable, Sendable { case pass, swallow, superTap, run(ShellAction), recorded(Chord), cancelled }
    public var table = ShortcutTable(), superKey = SuperKey.rightCommand, recording = false
    private var tap = SuperTap(), held: Set<Int64> = []
    public init() {}
    public mutating func pointer() { tap.cancel() }
    /// After macOS switched the tap off, nothing known about held keys can be trusted.
    public mutating func reset() { tap.cancel(); held = [] }
    public mutating func flagsChanged(key: Int64, flags: UInt64) -> Decision { tap.flagsChanged(key: key, flags: flags, superKey: superKey) && !recording ? .superTap : .pass }
    public mutating func keyDown(key: Int64, flags: UInt64, repeated: Bool) -> Decision {
        tap.cancel()
        // Whoever got the press gets the repeats and the release, whatever is held by then.
        if repeated { return held.contains(key) ? .swallow : .pass }
        held.remove(key) // a release we never saw
        if recording {
            held.insert(key)
            guard let chord = Chord(key: key, flags: flags, superKey: superKey) else { return .swallow }
            return chord == Chord(53, []) ? .cancelled : .recorded(chord)
        }
        guard let chord = Chord(key: key, flags: flags, superKey: superKey), let action = table.action(for: chord) else { return .pass }
        held.insert(key)
        return .run(action)
    }
    /// An app must not see the release of a key whose press it never got.
    public mutating func keyUp(key: Int64) -> Decision { held.remove(key) == nil ? .pass : .swallow }
}
