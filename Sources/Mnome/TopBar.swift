import AppKit
import SwiftUI
import Network
import IOKit.ps
import MnomeSupport

@MainActor final class BarStatus: ObservableObject {
    @Published var clock = StatusText.clock(Date())
    @Published var battery: String?
    @Published var batteryPercent: Int?
    @Published var charging = false
    @Published var network = "Checking network connection"
    /// The display whose quick settings were asked for.
    @Published var menuRequest: (id: UUID, display: UInt64)?
    private var monitor: NWPathMonitor?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    func start() {
        stop(); refresh()
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let kind = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet" : path.usesInterfaceType(.cellular) ? "Cellular" : "Network"
            let text = StatusText.network(available: path.status == .satisfied, kind: kind)
            Task { @MainActor in self?.network = text }
        }
        monitor.start(queue: DispatchQueue(label: "dev.mnome.network"))
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
    }
    func stop() {
        timer?.invalidate(); timer = nil; monitor?.cancel(); monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers = []
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }; powerSource = nil
    }
    func refresh() {
        clock = StatusText.clock(Date()); battery = nil; batteryPercent = nil; charging = false
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

struct TopBarView: View {
    @ObservedObject var status: BarStatus
    @ObservedObject var model: Model
    @ObservedObject var dock: DockModel
    @ObservedObject var macChrome: MacChromeController
    let activities: () -> Void
    let actions: QuickActions
    var display: UInt64 = 0
    @State private var showingMenu = false
    private var statusLabel: String { "System status and Mnome settings, \(status.battery ?? "No battery"), \(status.network)" }
    var body: some View {
        ZStack {
            Text(status.clock).font(.callout.weight(.semibold)).accessibilityLabel("Date and time, \(status.clock)")
            HStack {
                Button(action: activities) { Text("Activities").font(.callout.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 3) }
                    .buttonStyle(ShellButtonStyle()).accessibilityHint("Open or close the window overview")
                Spacer()
                Button { showingMenu.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: status.network == "No network connection" ? "network.slash" : "network")
                        if let percent = status.batteryPercent { Image(systemName: StatusText.batterySymbol(percent: percent, charging: status.charging)) }
                        Image(systemName: "power")
                    }.font(.callout).padding(.horizontal, 12).padding(.vertical, 3)
                }.buttonStyle(ShellButtonStyle()).help(status.network).accessibilityLabel(statusLabel)
                .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
                    QuickSettingsView(status: status, model: model, dock: dock, macChrome: macChrome, actions: actions, dismiss: { showingMenu = false }).shellTheme()
                }
            }.padding(.horizontal, 8)
        }.foregroundStyle(.white).frame(height: 32).background(ShellPalette.panel).shellTheme()
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
            Divider().overlay(Color.white.opacity(0.15))
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
            let frame = TopBarGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top)
            let panel = TopBarPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]; panel.isOpaque = true
            panel.contentView = NSHostingView(rootView: TopBarView(status: status, model: model, dock: dock, macChrome: macChrome, activities: activities, actions: actions, display: WindowManager.displayID(screen)))
            panel.orderFrontRegardless(); panels.append(panel)
        }
    }
    func focus() { panels.first?.takeKeyboard() }
    /// On the display under the pointer.
    func toggleQuickSettings() { guard enabled, let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }; status.menuRequest = (UUID(), WindowManager.displayID(screen)) }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        status.stop(); panels.forEach { $0.close() }; panels = []
    }
}
