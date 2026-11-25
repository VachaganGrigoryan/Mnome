import AppKit
import MnomeSupport

/// Feeds key events to the router. Runs on its own thread: macOS holds every key press in the system until we answer.
final class EventTap: @unchecked Sendable {
    /// On the main thread.
    var onDecision: @MainActor (KeyRouter.Decision) -> Void = { _ in }
    var onMedia: @MainActor (MediaKey) -> Void = { _ in }
    private let thread = RunLoopThread("dev.mnome.keys")
    private var keys: CFMachPort?, pointer: CFMachPort?, router = KeyRouter() // only on the tap thread
    private var media: (volume: Bool, brightness: Bool) = (false, false) // tap thread
    /// Which of the volume and brightness keys Mnome answers; the rest stay the Mac's.
    func takeMedia(volume: Bool, brightness: Bool) { thread.perform { self.media = (volume, brightness) } }

    /// When a release was missed, for example while macOS protected a password field.
    func endSwitcher() { thread.perform { self.router.reset() } }
    func configure(_ table: ShortcutTable, _ superKey: SuperKey, recording: Bool, commandTab: Bool) { thread.perform { self.router.table = table; self.router.superKey = superKey; self.router.recording = recording; self.router.commandTab = commandTab } }
    func start() -> Bool { thread.sync { self.open() } }
    func stop() { thread.sync { self.close() } }

    // Tap thread
    private func open() -> Bool {
        guard keys == nil else { return true }
        router.reset()
        let me = Unmanaged.passUnretained(self).toOpaque() // lives as long as the app
        func mask(_ types: [CGEventType]) -> CGEventMask { types.reduce(0) { $0 | 1 << $1.rawValue } }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask([.flagsChanged, .keyDown, .keyUp]) | 1 << 14 /* NX_SYSDEFINED: volume, brightness */, callback: { _, type, event, me in
            guard let me else { return Unmanaged.passUnretained(event) }
            return Unmanaged<EventTap>.fromOpaque(me).takeUnretainedValue().key(type, event) ? Unmanaged.passUnretained(event) : nil
        }, userInfo: me) else { return false }
        keys = tap; CFRunLoopAddSource(thread.loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        // Listening only, so the pointer is never slowed down.
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask([.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]), callback: { _, type, event, me in
            if let me { Unmanaged<EventTap>.fromOpaque(me).takeUnretainedValue().pointed(type) }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) { pointer = tap; CFRunLoopAddSource(thread.loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes) }
        return true
    }
    private func close() { for tap in [keys, pointer] { if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) } }; keys = nil; pointer = nil; router.reset() }
    private func pointed(_ type: CGEventType) { if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let pointer { CGEvent.tapEnable(tap: pointer, enable: true) } }; router.pointer() }
    private func key(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type.rawValue == 14 { return mediaKey(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode), flags = event.flags.rawValue
        let decision: KeyRouter.Decision
        switch type {
        case .flagsChanged: decision = router.flagsChanged(key: code, flags: flags)
        case .keyDown: decision = router.keyDown(key: code, flags: flags, repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp: decision = router.keyUp(key: code)
        default: // macOS switched it off, for example after a slow moment
            if router.reset() { DispatchQueue.main.async { MainActor.assumeIsolated { self.onDecision(.switcher(.cancel)) } } }
            if let keys { CGEvent.tapEnable(tap: keys, enable: true) }
            return true
        }
        switch decision {
        case .pass: return true
        case .swallow: return false
        case .superTap, .run, .recorded, .cancelled, .switcher:
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onDecision(decision) } }
            return type == .flagsChanged // the modifier itself always reaches apps
        }
    }
}

extension EventTap {
    /// Option keeps the Mac's meaning (Option+volume opens Sound settings).
    private func mediaKey(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), let (key, down) = MediaKey.parse(subtype: ns.subtype.rawValue, data1: ns.data1), !event.flags.contains(.maskAlternate) else { return true }
        let ours = switch key { case .volumeUp, .volumeDown, .mute: media.volume; case .brightnessUp, .brightnessDown: media.brightness }
        guard ours else { return true }
        if down { DispatchQueue.main.async { MainActor.assumeIsolated { self.onMedia(key) } } }
        return false
    }
}

/// The person's shortcuts, saved, and the tap that listens for them.
@MainActor final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    @Published private(set) var table = ShortcutTable(stored: UserDefaults.standard.data(forKey: "shortcuts"))
    @Published private(set) var superKey = UserDefaults.standard.string(forKey: "superKey").flatMap(SuperKey.init(rawValue:)) ?? .rightCommand
    @Published private(set) var enabled = UserDefaults.standard.object(forKey: "shortcutsEnabled") as? Bool ?? true
    /// Left Command+Tab opens Mnome's switcher, not the Mac's.
    @Published var commandTab = UserDefaults.standard.object(forKey: "commandTab") as? Bool ?? true { didSet { UserDefaults.standard.set(commandTab, forKey: "commandTab"); apply() } }
    @Published private(set) var recording: ShellAction?
    @Published private(set) var message: String?
    @Published private(set) var listening = false
    var run: (ShellAction) -> Void = { _ in }, superTapped: () -> Void = {}, switcher: (KeyRouter.SwitcherKey) -> Void = { _ in }, media: (MediaKey) -> Void = { _ in }
    func takeMedia(volume: Bool, brightness: Bool) { tap.takeMedia(volume: volume, brightness: brightness) }
    private let tap = EventTap()
    private var session = UUID()
    private init() { NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.stopRecording() } } }

    /// Call again whenever Accessibility may have been granted.
    func start() {
        tap.onDecision = { [weak self] in self?.handle($0) }; tap.onMedia = { [weak self] in self?.media($0) }
        guard enabled else { tap.stop(); listening = false; return }
        listening = tap.start(); apply()
        if !listening { NSLog("Mnome: the keyboard could not be listened to") }
    }
    private func apply() { tap.configure(table, superKey, recording: recording != nil, commandTab: commandTab) }
    private func handle(_ decision: KeyRouter.Decision) {
        switch decision {
        case .superTap: superTapped()
        case let .run(action): run(action)
        case let .recorded(chord): if let action = recording { recording = nil; set(action, chord == Chord(51, []) ? nil : chord) }
        case .cancelled: recording = nil; apply()
        case let .switcher(key): switcher(key)
        case .pass, .swallow: break
        }
    }
    /// While recording no key reaches any app, so it always ends by itself.
    func record(_ action: ShellAction) {
        message = nil; recording = recording == action ? nil : action; apply()
        let mine = UUID(); session = mine
        Task { try? await Task.sleep(for: .seconds(8)); if session == mine { stopRecording() } }
    }
    func endSwitcher() { tap.endSwitcher() }
    func stopRecording() { guard recording != nil else { return }; recording = nil; apply() }
    func set(_ action: ShellAction, _ chord: Chord?) {
        switch table.set(action, chord) {
        case nil: message = nil; UserDefaults.standard.set(table.stored, forKey: "shortcuts")
        case .notAllowed: message = "Use a key together with Super, Control or Option."
        case let .taken(owner): message = "\(chord?.label ?? "") is already used for “\(owner.title)”."
        }
        apply()
    }
    func reset() { table.reset(); message = nil; UserDefaults.standard.removeObject(forKey: "shortcuts"); apply() }
    func use(_ key: SuperKey) { superKey = key; UserDefaults.standard.set(key.rawValue, forKey: "superKey"); apply() }
    func setEnabled(_ on: Bool) { enabled = on; UserDefaults.standard.set(on, forKey: "shortcutsEnabled"); stopRecording(); start() }
}
