import AppKit
import SwiftUI
import Network
import IOKit.ps
import CoreAudio
import AudioToolbox
import CoreWLAN
import MnomeSupport

@MainActor final class BarStatus: ObservableObject {
    @Published var clock = StatusText.clock(Date())
    @Published var battery: String?
    @Published var batteryPercent: Int?
    @Published var charging = false
    @Published var network = "Checking network connection"
    @Published var online = true
    @Published var wifi = false
    @Published var rssi: Int?
    @Published var volume: (level: Double, muted: Bool)?
    @Published var workspaces = BarWorkspaces()
    /// The display whose quick settings were asked for.
    /// The menu open from the bar, as "date-<display>" or "quick-<display>".
    @Published var openMenu: String?
    /// GNOME's bar turns transparent over the overview.
    @Published var inOverview = false
    /// The front app's menu titles, where its hidden Mac menu bar has them.
    @Published var appMenus = AppMenus.Bar()
    /// The apps' menu bar icons, drawn by Mnome.
    @Published var appIcons: [AppIcons.Icon] = []
    /// Command is held: the bar's items can be dragged to another place.
    @Published var commandHeld = false
    private var monitor: NWPathMonitor?
    private var timer: Timer?
    private var clockTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var audioDevice = AudioObjectID(kAudioObjectUnknown)
    private lazy var audioChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor in self?.readVolume() } }
    private lazy var deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor in self?.followOutputDevice() } }
    func start() {
        stop(); refresh()
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let kind = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet" : path.usesInterfaceType(.cellular) ? "Cellular" : "Network"
            let text = StatusText.network(available: path.status == .satisfied, kind: kind), online = path.status == .satisfied, wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor in self?.network = text; self?.online = online; self?.wifi = wifi; self?.readSignal() }
        }
        monitor.start(queue: DispatchQueue(label: "dev.mnome.network"))
        tickOnTheMinute()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        for name in [NSLocale.currentLocaleDidChangeNotification, NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name("NSSystemClockDidChangeNotification")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let status = Unmanaged<BarStatus>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in status.refresh() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            powerSource = source; CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        var defaultOutput = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutput, .main, deviceChanged)
        followOutputDevice()
    }
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    /// Volume and mute are watched on the current output device; a new default device moves the watch.
    private func followOutputDevice() {
        watchAudio(false)
        var device = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size), address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) != noErr { device = AudioObjectID(kAudioObjectUnknown) }
        audioDevice = device; watchAudio(true); readVolume()
    }
    private func watchAudio(_ on: Bool) {
        guard audioDevice != kAudioObjectUnknown else { return }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector)
            guard AudioObjectHasProperty(audioDevice, &address) else { continue }
            if on { AudioObjectAddPropertyListenerBlock(audioDevice, &address, .main, audioChanged) } else { AudioObjectRemovePropertyListenerBlock(audioDevice, &address, .main, audioChanged) }
        }
    }
    private func readVolume() {
        var level = Float32(0), muted = UInt32(0), size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard audioDevice != kAudioObjectUnknown, AudioObjectGetPropertyData(audioDevice, &address, 0, nil, &size, &level) == noErr else { volume = nil; return } // no adjustable output
        address = Self.address(kAudioDevicePropertyMute); size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(audioDevice, &address, 0, nil, &size, &muted) != noErr { muted = 0 }
        volume = (Double(level), muted != 0)
    }
    /// False when the output has no volume of its own (HDMI and some USB): the Mac then keeps its keys.
    var volumeSettable: Bool {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume), settable = DarwinBoolean(false)
        return audioDevice != kAudioObjectUnknown && AudioObjectIsPropertySettable(audioDevice, &address, &settable) == noErr && settable.boolValue
    }
    /// Raising the volume unmutes, as GNOME and the Mac do.
    @discardableResult func setVolume(_ level: Double) -> Bool {
        var value = Float32(min(1, max(0, level))), address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        let done = volumeSettable && AudioObjectSetPropertyData(audioDevice, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
        if done, level > 0, volume?.muted == true { setMuted(false) }
        readVolume(); return done
    }
    @discardableResult func setMuted(_ muted: Bool) -> Bool {
        var value = UInt32(muted ? 1 : 0), address = Self.address(kAudioDevicePropertyMute)
        let done = audioDevice != kAudioObjectUnknown && AudioObjectSetPropertyData(audioDevice, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        readVolume(); return done
    }
    /// Signal strength needs no location permission (the network name would).
    private func readSignal() { rssi = wifi ? CWWiFiClient.shared().interface().map { $0.rssiValue() } : nil }
    /// GNOME's clock changes exactly when the minute does, not up to 30 s later.
    private func tickOnTheMinute() {
        let now = Date(), next = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: next + 0.05), interval: 0, repeats: false) { [weak self] _ in Task { @MainActor in
            guard let self, self.clockTimer != nil else { return }
            self.clock = StatusText.clock(Date()); self.tickOnTheMinute()
        } }
        timer.tolerance = 0.1; RunLoop.main.add(timer, forMode: .common); clockTimer = timer
    }
    func stop() {
        clockTimer?.invalidate(); clockTimer = nil
        timer?.invalidate(); timer = nil; monitor?.cancel(); monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers = []
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }; powerSource = nil
        var defaultOutput = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutput, .main, deviceChanged)
        watchAudio(false); audioDevice = AudioObjectID(kAudioObjectUnknown)
    }
    func refresh() {
        clock = StatusText.clock(Date()); readSignal(); battery = nil; batteryPercent = nil; charging = false
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any], description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int, maximum = description[kIOPSMaxCapacityKey] as? Int
            charging = description[kIOPSIsChargingKey] as? Bool ?? false
            battery = StatusText.battery(current: current, maximum: maximum, charging: charging)
            batteryPercent = StatusText.batteryPercent(current: current, maximum: maximum)
            break
        }
    }
}

struct QuickActions {
    var openMnome: () -> Void = {}, preferences: () -> Void = {}, shortcuts: () -> Void = {}, about: () -> Void = {}, quit: () -> Void = {}
    var systemSettings: () -> Void = {}, networkSettings: () -> Void = {}, batterySettings: () -> Void = {}
    var lock: () -> Void = {}, focusDock: () -> Void = {}, focusTopBar: () -> Void = {}, setWorkspaces: (Bool) -> Void = { _ in }, toggleTopBar: () -> Void = {}, toggleDock: () -> Void = {}
    var setShortcut: (ShortcutChoice) -> Void = { _ in }, removeFavorite: (String) -> Void = { _ in }, toggleMacChrome: () -> Void = {}, bringBackWindows: () -> Void = {}
}

struct BarWorkspaces: Equatable { var count = 1, current = 0, on = false }

/// GNOME's `#panel .panel-button`: a pill inside a 3 px transparent border, ink at 17% hover, 28% pressed or open, 32% both.
struct PanelButtonStyle: ButtonStyle {
    var open = false
    /// Each side; the Mac's menu titles need less than GNOME's 12.
    var padding: CGFloat = 12
    func makeBody(configuration: Configuration) -> some View { PanelButtonBody(configuration: configuration, open: open, padding: padding) }
}
private struct PanelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let open: Bool, padding: CGFloat
    @State private var hover = false
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast
    private var ink: CGFloat {
        let down = configuration.isPressed || open, level: CGFloat = down ? (hover ? 0.32 : 0.28) : hover || focused ? 0.17 : 0
        return level == 0 ? 0 : level + (contrast == .increased ? 0.13 : 0)
    }
    var body: some View {
        configuration.label.padding(.horizontal, padding).frame(maxHeight: .infinity)
            .background(Capsule().fill(ShellPalette.ink(ink)))
            .overlay(Capsule().stroke(focused ? ShellPalette.toggleOn : contrast == .increased ? ShellPalette.ink(0.6) : .clear, lineWidth: 2))
            .contentShape(Capsule()).padding(3).onHover { hover = $0 }.animation(.easeOut(duration: 0.15), value: ink)
    }
}
/// The Activities button: GNOME 45's workspace dots.
struct WorkspaceDotsView: View {
    let workspaces: BarWorkspaces
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        HStack(spacing: WorkspaceDots.spacing) {
            ForEach(Array(WorkspaceDots.dots(count: workspaces.count, current: workspaces.current, on: workspaces.on).enumerated()), id: \.offset) { _, current in
                let size = current ? WorkspaceDots.active : WorkspaceDots.inactive
                Capsule().fill(ShellPalette.text.opacity(current || contrast == .increased ? 1 : 0.5)).frame(width: size.width, height: size.height)
            }
        }.animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.25), value: workspaces) // ease-out-cubic, as GNOME's workspace switch
    }
}

struct TopBarView: View {
    @ObservedObject var status: BarStatus
    @ObservedObject var model: Model
    @ObservedObject var dock: DockModel
    @ObservedObject var macChrome: MacChromeController
    let activities: () -> Void
    let actions: QuickActions
    var display: UInt64 = 0
    /// The width left of the notch, where the clock goes instead of behind it.
    var besideNotch: CGFloat?
    var menu: (String) -> Void = { _ in }
    /// The display's frame, in AppKit coordinates.
    var screen: CGRect = .zero
    var appMenu: (Int) -> Void = { _ in }
    var appIcon: (AppIcons.Icon) -> Void = { _ in }
    private var dotsWidth: CGFloat {
        let dots = WorkspaceDots.dots(count: status.workspaces.count, current: status.workspaces.current, on: status.workspaces.on)
        return dots.reduce(0) { $0 + ($1 ? WorkspaceDots.active.width : WorkspaceDots.inactive.width) } + WorkspaceDots.spacing * CGFloat(max(0, dots.count - 1))
    }
    /// With the app's menus shown, Activities takes the Apple menu's place, up to where the Mac's titles start, so
    /// every title can sit exactly where the Mac has it.
    fileprivate func appleSlot(_ layout: BarLayout) -> CGFloat? {
        guard !status.inOverview, layout.left.first == .activities, let first = status.appMenus.items.first, onMenuBarDisplay(first.frame) else { return nil }
        return first.frame.minX - screen.minX
    }
    /// The Mac's menu bar, and so the app menus and icons, is on one display: the one with the front window.
    fileprivate func onMenuBarDisplay(_ frame: CGRect?) -> Bool {
        guard let frame else { return false }
        return (screen.minX..<screen.maxX).contains(frame.minX) && abs(frame.minY - (WindowManager.primaryHeight - screen.maxY)) < 50
    }
    private var statusLabel: String { "System status and Mnome settings, \(status.battery ?? "No battery"), \(status.network)" + (status.volume.map { $0.muted ? ", muted" : ", volume \(Int(($0.level * 100).rounded()))%" } ?? "") }
    @AppStorage("topBarLayout") private var layoutData = Data()
    @State private var dragged: BarItem?
    @State private var dragX: CGFloat = 0
    var body: some View {
        let layout = BarLayout(data: layoutData)
        ZStack {
            zone(layout.center, layout).frame(width: besideNotch.map { max(0, $0 - 12) }, alignment: .trailing).frame(maxWidth: .infinity, alignment: besideNotch == nil ? .center : .leading)
            HStack(spacing: 0) { zone(layout.left, layout); Spacer(minLength: 0); zone(layout.right, layout) }
            appMenus(layout).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }.frame(minHeight: 32, maxHeight: .infinity).background(status.inOverview ? Color.clear : ShellPalette.panel).overlay(alignment: .bottom) { if !status.inOverview { ShellPalette.panelEdge.frame(height: 0.5) } }
        .coordinateSpace(name: "bar").shellTheme(follows: !status.inOverview) // white over the dark overview, in either style
    }
    private func zone(_ items: [BarItem], _ layout: BarLayout) -> some View {
        HStack(spacing: 0) { ForEach(items, id: \.self) { item($0, layout) } }
    }
    /// With Command held, an item can be dragged to another place in the bar, as on the Mac.
    private func item(_ item: BarItem, _ layout: BarLayout) -> some View {
        Group {
            switch item {
            case .activities:
                let slot = appleSlot(layout), natural = dotsWidth
                Button(action: activities) { WorkspaceDotsView(workspaces: status.workspaces).scaleEffect(slot.map { min(1, ($0 - 8) / natural) } ?? 1).frame(width: slot.map { $0 - 8 }) }
                    .buttonStyle(PanelButtonStyle(padding: slot == nil ? 12 : 4)).accessibilityLabel(WorkspaceDots.label(count: status.workspaces.count, current: status.workspaces.current, on: status.workspaces.on)).accessibilityHint("Open or close the window overview")
            case .clock:
                Button { menu("date") } label: { Text(status.clock).font(.adwaita(14.667, .bold)).monospacedDigit().lineLimit(1) }
                    .buttonStyle(PanelButtonStyle(open: status.openMenu == "date-\(display)")).accessibilityLabel("Date and time, \(status.clock)").accessibilityHint("Open the calendar")
            case .status:
                Button { menu("quick") } label: {
                    HStack(spacing: 12) {
                        AdwaitaIcon(name: StatusIcons.network(available: status.online, wifi: status.wifi, rssi: status.rssi), fallback: status.online ? "network" : "network.slash")
                        if let volume = status.volume { AdwaitaIcon(name: StatusIcons.volume(level: volume.level, muted: volume.muted), fallback: volume.muted ? "speaker.slash" : "speaker.wave.2") }
                        if let percent = status.batteryPercent { AdwaitaIcon(name: StatusIcons.battery(percent: percent, charging: status.charging), fallback: StatusText.batterySymbol(percent: percent, charging: status.charging)) }
                        else { AdwaitaIcon(name: "system-shutdown-symbolic", fallback: "power") }
                    }
                }.buttonStyle(PanelButtonStyle(open: status.openMenu == "quick-\(display)")).help(status.network).accessibilityLabel(statusLabel)
            case .appIcons:
                if onMenuBarDisplay(status.appIcons.first?.frame) {
                    HStack(spacing: 0) {
                        ForEach(status.appIcons) { icon in
                            Button {} label: { Image(nsImage: icon.image).renderingMode(.template).frame(width: max(0, icon.frame.width - 8)) }
                                .buttonStyle(PanelButtonStyle()).simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in appIcon(icon) })
                                .accessibilityLabel("App menu bar icon \(icon.id + 1)").accessibilityAction { appIcon(icon) }
                        }
                    }
                }
            }
        }
        .offset(x: dragged == item ? dragX : 0).zIndex(dragged == item ? 1 : 0)
        .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("bar"))
            .onChanged { dragged = item; dragX = $0.translation.width }
            .onEnded { value in
                let widths = Dictionary(uniqueKeysWithValues: BarItem.allCases.map { ($0, width($0)) })
                layoutData = layout.dropping(item, at: value.location.x, width: screen.width, widths: widths).data
                dragged = nil; dragX = 0
            }, including: status.commandHeld || dragged != nil ? .all : .subviews)
    }
    /// An item's width in the bar, for the app menus' room and for dropping.
    private func width(_ item: BarItem) -> CGFloat {
        switch item {
        case .activities: return appleSlot(BarLayout(data: layoutData)) ?? dotsWidth + 24
        case .clock: return (status.clock as NSString).size(withAttributes: [.font: NSFont(name: Adwaita.family, size: 14.667) ?? .boldSystemFont(ofSize: 14.667)]).width + 24
        case .status: let icons: CGFloat = status.volume == nil ? 2 : 3; return icons * 16 + (icons - 1) * 12 + 24
        case .appIcons: return onMenuBarDisplay(status.appIcons.first?.frame) ? status.appIcons.reduce(0) { $0 + max(0, $1.frame.width - 8) + 24 } : 0
        }
    }
}

extension TopBarView {
    /// Each title where the Mac has it, so the app's real menu opens under it. Only on the display the Mac's menu bar
    /// is on, and not in the overview. They fill the room between the left zone and the next item.
    @ViewBuilder fileprivate func appMenus(_ layout: BarLayout) -> some View {
        let items = status.appMenus.items
        if !status.inOverview, onMenuBarDisplay(items.first?.frame) {
            let start = layout.left.reduce(0) { $0 + width($1) }, center = layout.center.reduce(0) { $0 + width($1) }
            let end = layout.center.isEmpty ? screen.width - layout.right.reduce(0) { $0 + width($1) } : besideNotch.map { $0 - 12 - center } ?? (screen.width - center) / 2
            let shown = AppMenuStrip.layout(items.map { (x: $0.frame.minX - screen.minX, width: $0.frame.width) }, start: start, end: end - 8)
            ZStack(alignment: .leading) {
                ForEach(shown, id: \.self) { i in
                    // Pressed on mouse-down, as the Mac's titles: the button's own action would wait for mouse-up.
                    Button {} label: { Text(items[i].title).font(.adwaita(13.5, i == 0 ? .bold : .regular)).lineLimit(1).minimumScaleFactor(0.75).frame(width: max(0, items[i].frame.width - 8)) }
                        .buttonStyle(PanelButtonStyle(padding: 4)).simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in appMenu(i) })
                        .offset(x: items[i].frame.minX - screen.minX).accessibilityLabel("\(items[i].title) menu").accessibilityAction { appMenu(i) }
                }
            }.frame(maxHeight: .infinity)
        }
    }
}

final class TopBarPanel: NSPanel {
    /// Only while asked for: when the overview closes, macOS gives the keyboard to any of our windows that would take it, and typing would go nowhere.
    private var wantsKeyboard = false
    func takeKeyboard() { wantsKeyboard = true; NSApp.activate(); makeKeyAndOrderFront(nil) }
    override func resignKey() { super.resignKey(); wantsKeyboard = false }
    override var canBecomeKey: Bool { wantsKeyboard }
    override var canBecomeMain: Bool { false }
}
@MainActor final class TopBarController {
    let status = BarStatus()
    private var panels: [TopBarPanel] = []
    private var observer: NSObjectProtocol?
    var enabled: Bool { UserDefaults.standard.object(forKey: "showTopBar") as? Bool ?? true }
    var activities: () -> Void = {}
    var actions = QuickActions()
    var model: Model?
    var dock: DockModel?
    var macChrome: MacChromeController?
    /// The front app's menus; nil while the Mac's menu bar is the bar.
    var appMenus: AppMenus?
    var appIcons: AppIcons?
    private var commandWatch: [Any] = []
    func start() {
        status.start(); rebuild()
        if commandWatch.isEmpty { // the bar's items move with Command held, wherever the keyboard is
            let flags: (NSEvent) -> Void = { [weak self] event in MainActor.assumeIsolated { let held = event.modifierFlags.contains(.command); if self?.status.commandHeld != held { self?.status.commandHeld = held } } }
            commandWatch = [NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) as Any, NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 } as Any]
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.rebuild() } }
    }
    func setVisible(_ visible: Bool) { UserDefaults.standard.set(visible, forKey: "showTopBar"); rebuild() }
    func rebuild() {
        panels.forEach { $0.close() }; panels = []
        guard enabled, let model, let dock, let macChrome else { return }
        for screen in NSScreen.screens {
            let frame = frame(on: screen)
            let panel = TopBarPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.level = replacesMenuBar ? NSWindow.Level(rawValue: 27) : .floating // above the Mac menu bar (24) and its status items (25): an auto-hidden menu bar that slides down when the pointer touches the top stays underneath
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.contentView = NSHostingView(rootView: TopBarView(status: status, model: model, dock: dock, macChrome: macChrome, activities: activities, actions: actions, display: WindowManager.displayID(screen), besideNotch: replacesMenuBar ? screen.auxiliaryTopLeftArea?.width : nil, menu: { [weak self] in self?.toggleMenu($0, on: screen) }, screen: screen.frame, appMenu: { [weak self] in self?.appMenus?.open($0) }, appIcon: { [weak self] in self?.appIcons?.press($0) }))
            panel.setFrame(frame, display: true); panel.orderFrontRegardless(); panels.append(panel)
        }
    }
    private var replacesMenuBar: Bool { macChrome?.hidden.contains(.menuBar) ?? false }
    func frame(on screen: NSScreen) -> CGRect { TopBarGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top, replacesMenuBar: replacesMenuBar) }
    func focus() { panels.first?.takeKeyboard() }
    let menus = ShellMenus(), agenda = Agenda(), controls = SystemControls()
    /// On the display under the pointer.
    func toggleQuickSettings() { if let item = itemFrame("quick") { toggleMenu("quick", under: item) } else if let screen = pointerScreen { toggleMenu("quick", on: screen) } }
    func toggleDateMenu() { if let item = itemFrame("date") { toggleMenu("date", under: item) } else if let screen = pointerScreen { toggleMenu("date", on: screen) } }
    /// In the Mac's menu bar: where Mnome's item for a menu is, in screen coordinates.
    var itemFrame: (String) -> CGRect? = { _ in nil }
    private var pointerScreen: NSScreen? { enabled ? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main : nil }
    /// Suspend acts at once; the others ask on the main display, with GNOME's countdown.
    func endSession(_ action: SessionAction) {
        guard action.asks else { _ = Session.perform(action); return }
        guard let screen = NSScreen.screens.first else { return }
        menus.show("end-session", in: screen.frame, place: .middle, EndSessionView(action: action, cancel: { [weak self] in self?.menus.close() }, confirm: { [weak self] in self?.menus.close(); _ = Session.perform(action) }).shellTheme(follows: true))
    }
    func toggleRunDialog() {
        guard let screen = NSScreen.screens.first else { return }
        menus.toggle("run", in: screen.frame, place: .middle, RunDialogView(close: { [weak self] in self?.menus.close() }).shellTheme(follows: true))
    }
    /// Under one of Mnome's items in the Mac's menu bar.
    func toggleMenu(_ kind: String, under item: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: item.midX, y: item.midY)) }) ?? NSScreen.main else { return }
        toggleMenu(kind, on: screen, place: .under(item), anchor: screen.frame)
    }
    func toggleMenu(_ kind: String, on screen: NSScreen, place: ShellMenus.Place? = nil, anchor: CGRect? = nil) {
        guard let model, let dock, let macChrome else { return }
        menus.changed = { [weak self] in self?.status.openMenu = $0 }
        let id = "\(kind)-\(WindowManager.displayID(screen))", bar = anchor ?? frame(on: screen)
        let place = place ?? zonePlace(kind == "date" ? .clock : .status, bar: bar)
        if kind == "date" { menus.toggle(id, in: bar, place: place, DateMenuView(agenda: agenda).shellTheme(follows: true)) }
        else { menus.toggle(id, in: bar, place: place, QuickSettingsView(status: status, controls: controls, model: model, dock: dock, macChrome: macChrome, actions: actions, dismiss: { [weak self] in self?.menus.close() }, endSession: { [weak self] in self?.endSession($0) }).shellTheme(follows: true)) }
    }
    /// A menu opens under its item: at the left edge, in the middle or at the right edge, wherever the item was put.
    private func zonePlace(_ item: BarItem, bar: CGRect) -> ShellMenus.Place {
        let layout = BarLayout(data: UserDefaults.standard.data(forKey: "topBarLayout"))
        return layout.left.contains(item) ? .under(CGRect(x: bar.minX, y: bar.minY, width: 0, height: bar.height)) : layout.center.contains(item) ? .center : .trailing
    }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        menus.close(); status.stop(); panels.forEach { $0.close() }; panels = []
    }
}
