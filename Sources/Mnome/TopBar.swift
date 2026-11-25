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
    @Published var menuRequest: (id: UUID, display: UInt64)?
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
    var focusDock: () -> Void = {}, focusTopBar: () -> Void = {}, setWorkspaces: (Bool) -> Void = { _ in }, toggleTopBar: () -> Void = {}, toggleDock: () -> Void = {}
    var setShortcut: (ShortcutChoice) -> Void = { _ in }, removeFavorite: (String) -> Void = { _ in }, toggleMacChrome: () -> Void = {}, bringBackWindows: () -> Void = {}
}

struct BarWorkspaces: Equatable { var count = 1, current = 0, on = false }

/// GNOME's `#panel .panel-button`: a pill inside a 3 px transparent border, ink at 17% hover, 28% pressed or open, 32% both.
struct PanelButtonStyle: ButtonStyle {
    var open = false
    func makeBody(configuration: Configuration) -> some View { PanelButtonBody(configuration: configuration, open: open) }
}
private struct PanelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let open: Bool
    @State private var hover = false
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast
    private var ink: CGFloat {
        let down = configuration.isPressed || open, level: CGFloat = down ? (hover ? 0.32 : 0.28) : hover || focused ? 0.17 : 0
        return level == 0 ? 0 : level + (contrast == .increased ? 0.13 : 0)
    }
    var body: some View {
        configuration.label.padding(.horizontal, 12).frame(maxHeight: .infinity)
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
    @State private var showingMenu = false
    private var statusLabel: String { "System status and Mnome settings, \(status.battery ?? "No battery"), \(status.network)" + (status.volume.map { $0.muted ? ", muted" : ", volume \(Int(($0.level * 100).rounded()))%" } ?? "") }
    var body: some View {
        ZStack {
            Text(status.clock).font(.adwaita(14.667, .bold)).monospacedDigit().lineLimit(1).accessibilityLabel("Date and time, \(status.clock)")
                .frame(width: besideNotch.map { max(0, $0 - 12) }, alignment: .trailing).frame(maxWidth: .infinity, alignment: besideNotch == nil ? .center : .leading)
            HStack(spacing: 0) {
                Button(action: activities) { WorkspaceDotsView(workspaces: status.workspaces) }
                    .buttonStyle(PanelButtonStyle()).accessibilityLabel(WorkspaceDots.label(count: status.workspaces.count, current: status.workspaces.current, on: status.workspaces.on)).accessibilityHint("Open or close the window overview")
                Spacer()
                Button { showingMenu.toggle() } label: {
                    HStack(spacing: 12) {
                        AdwaitaIcon(name: StatusIcons.network(available: status.online, wifi: status.wifi, rssi: status.rssi), fallback: status.online ? "network" : "network.slash")
                        if let volume = status.volume { AdwaitaIcon(name: StatusIcons.volume(level: volume.level, muted: volume.muted), fallback: volume.muted ? "speaker.slash" : "speaker.wave.2") }
                        if let percent = status.batteryPercent { AdwaitaIcon(name: StatusIcons.battery(percent: percent, charging: status.charging), fallback: StatusText.batterySymbol(percent: percent, charging: status.charging)) }
                        else { AdwaitaIcon(name: "system-shutdown-symbolic", fallback: "power") }
                    }
                }.buttonStyle(PanelButtonStyle(open: showingMenu)).help(status.network).accessibilityLabel(statusLabel)
                .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
                    QuickSettingsView(status: status, model: model, dock: dock, macChrome: macChrome, actions: actions, dismiss: { showingMenu = false }).shellTheme(follows: true)
                }
            }
        }.frame(minHeight: 32, maxHeight: .infinity).background(ShellPalette.panel).overlay(alignment: .bottom) { ShellPalette.panelEdge.frame(height: 0.5) }.shellTheme(follows: true)
        .onChange(of: status.menuRequest?.id) { _, _ in if status.menuRequest?.display == display { showingMenu.toggle() } }
    }
}

struct QuickSettingsView: View {
    @ObservedObject var status: BarStatus
    @ObservedObject var model: Model
    @ObservedObject var dock: DockModel
    @ObservedObject var macChrome: MacChromeController
    let actions: QuickActions
    let dismiss: () -> Void
    @AppStorage("showTopBar") private var topBarOn = true
    @AppStorage("showDock") private var dockOn = true
    @State private var section: String?
    private func run(_ action: @escaping () -> Void) -> () -> Void { { dismiss(); action() } }
    private func round(_ icon: String, _ label: String, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: run(action)) {
            Image(systemName: icon).frame(width: 36, height: 36).background(destructive ? ShellPalette.destructive : ShellPalette.toggle).clipShape(Circle())
        }.buttonStyle(ShellButtonStyle()).help(label).accessibilityLabel(label)
    }
    private func toggle(_ icon: String, _ title: String, _ subtitle: String?, on: Bool = false, expands: String? = nil, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: icon).frame(width: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(on ? Color.white.opacity(0.85) : ShellPalette.dim).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title).accessibilityAddTraits(on ? .isSelected : [])
            if let expands {
                Button { section = section == expands ? nil : expands } label: { Image(systemName: section == expands ? "chevron.up" : "chevron.right").font(.caption.weight(.bold)).frame(width: 20, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel("\(title) options").accessibilityValue(section == expands ? "Expanded" : "Collapsed")
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity).background(on ? ShellPalette.toggleOn : ShellPalette.toggle).clipShape(RoundedRectangle(cornerRadius: 999))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let battery = status.battery, let percent = status.batteryPercent {
                    Label(battery, systemImage: StatusText.batterySymbol(percent: percent, charging: status.charging)).font(.callout.weight(.semibold)).padding(.horizontal, 12).frame(height: 36).background(ShellPalette.toggle).clipShape(Capsule())
                }
                Spacer(minLength: 0)
                round("gearshape", "Mnome Preferences", actions.preferences)
                round("slider.horizontal.3", "System Settings", actions.systemSettings)
                round("keyboard", "Keyboard Shortcuts", actions.shortcuts)
                round("info.circle", "About Mnome", actions.about)
                round("power", "Quit Mnome", destructive: true, actions.quit)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                toggle(status.network == "No network connection" ? "network.slash" : "network", "Network", status.network, on: status.network != "No network connection", run(actions.networkSettings))
                toggle(status.batteryPercent.map { StatusText.batterySymbol(percent: $0, charging: status.charging) } ?? "battery.0", "Battery", status.battery ?? "Not available", run(actions.batterySettings))
                toggle("menubar.rectangle", "Top Bar", topBarOn ? "On" : "Off", on: topBarOn, actions.toggleTopBar)
                toggle("dock.rectangle", "Dock", dockOn ? "On" : "Off", on: dockOn, actions.toggleDock)
                toggle("command", "Shortcut", model.shortcutTitle, expands: "shortcut") { section = section == "shortcut" ? nil : "shortcut" }
                toggle("macwindow.badge.plus", "macOS Shell", macChrome.summary, on: !macChrome.hidden.isEmpty, actions.toggleMacChrome)
                toggle("star", "Favorites", "\(dock.favorites.count) pinned", expands: "favorites") { section = section == "favorites" ? nil : "favorites" }
            }
            if section == "shortcut" {
                BoxedList { ForEach(ShortcutChoice.all, id: \.title) { choice in CheckRow(title: choice.title, selected: model.shortcutTitle == choice.title) { actions.setShortcut(choice) } } }
            }
            if section == "favorites" {
                if dock.favorites.isEmpty { ActionRow(title: "No favorites", subtitle: "Pin apps from the launcher") }
                else { BoxedList { ForEach(dock.favorites) { favorite in
                    ActionRow(title: favorite.name, subtitle: dock.resolved(favorite) == nil ? "Unavailable" : nil, icon: "minus.circle", action: { actions.removeFavorite(favorite.id) })
                        .accessibilityLabel("Remove \(favorite.name) from favorites")
                } } }
            }
            Divider().overlay(ShellPalette.ink(0.15))
            VStack(spacing: 2) {
                row("Open Mnome", actions.openMnome); row("Focus Dock", actions.focusDock); row("Focus Top Bar", actions.focusTopBar)
            }
        }.padding(16).frame(width: 380).background(ShellPalette.popover).onExitCommand(perform: dismiss)
    }
    private func row(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: run(action)) { Text(title).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6) }.buttonStyle(ShellButtonStyle(radius: 8))
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
    func start() {
        status.start(); rebuild()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.rebuild() } }
    }
    func setVisible(_ visible: Bool) { UserDefaults.standard.set(visible, forKey: "showTopBar"); rebuild() }
    func rebuild() {
        panels.forEach { $0.close() }; panels = []
        guard enabled, let model, let dock, let macChrome else { return }
        for screen in NSScreen.screens {
            let frame = frame(on: screen)
            let panel = TopBarPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.level = replacesMenuBar ? NSWindow.Level(rawValue: 24) : .floating // lower, macOS pushes it down; higher, the Mac menus stay out of reach
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]; panel.isOpaque = true
            panel.contentView = NSHostingView(rootView: TopBarView(status: status, model: model, dock: dock, macChrome: macChrome, activities: activities, actions: actions, display: WindowManager.displayID(screen), besideNotch: replacesMenuBar ? screen.auxiliaryTopLeftArea?.width : nil))
            panel.setFrame(frame, display: true); panel.orderFrontRegardless(); panels.append(panel)
        }
    }
    private var replacesMenuBar: Bool { macChrome?.hidden.contains(.menuBar) ?? false }
    func frame(on screen: NSScreen) -> CGRect { TopBarGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top, replacesMenuBar: replacesMenuBar) }
    func focus() { panels.first?.takeKeyboard() }
    /// On the display under the pointer.
    func toggleQuickSettings() { guard enabled, let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }; status.menuRequest = (UUID(), WindowManager.displayID(screen)) }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        status.stop(); panels.forEach { $0.close() }; panels = []
    }
}
