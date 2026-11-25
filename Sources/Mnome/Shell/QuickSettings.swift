import AppKit
import SwiftUI
import MnomeSupport

/// GNOME's quick settings (`gnome-ref/shell/004-quick-settings.png`): round buttons, sliders, a grid of toggles,
/// and menus that open inside it. Mnome's own settings live under the Mnome toggle.
struct QuickSettingsView: View {
    @ObservedObject var status: BarStatus
    @ObservedObject var controls: SystemControls
    @ObservedObject var model: Model
    @ObservedObject var dock: DockModel
    @ObservedObject var macChrome: MacChromeController
    let actions: QuickActions
    let dismiss: () -> Void
    var endSession: (SessionAction) -> Void = { _ in }
    @AppStorage("showTopBar") private var topBarOn = true
    @AppStorage("showDock") private var dockOn = true
    @State private var section: String?
    private func run(_ action: @escaping () -> Void) -> () -> Void { { dismiss(); action() } }
    private func open(_ name: String) { section = section == name ? nil : name }
    var body: some View {
        VStack(spacing: 12) {
            top
            if section == "power" { power }
            sliders
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { network; bluetooth }
                GridRow {
                    QuickToggle(icon: "night-light-symbolic", fallback: "moon", title: "Night Light", on: controls.nightLight ?? false, enabled: controls.nightLight != nil) { controls.setNightLight(!(controls.nightLight ?? false)) }
                    QuickToggle(icon: "dark-mode-symbolic", fallback: "circle.lefthalf.filled", title: "Dark Style", on: controls.darkStyle ?? false, enabled: controls.darkStyle != nil) { controls.setDarkStyle(!(controls.darkStyle ?? false)) }
                }
                GridRow {
                    QuickToggle(icon: "keep-awake-symbolic", fallback: "cup.and.saucer", title: "Keep Awake", on: controls.keepAwake) { controls.setKeepAwake(!controls.keepAwake) }
                    QuickToggle(icon: "mnome-symbolic", fallback: "gearshape.2", title: "Mnome", subtitle: model.shortcutTitle, open: section == "mnome", menu: { open("mnome") }) { open("mnome") }
                }
            }
            if section == "mnome" { mnome }
        }
        .padding(18).frame(width: 400).background(ShellPalette.popover).clipShape(RoundedRectangle(cornerRadius: 36))
        .overlay(RoundedRectangle(cornerRadius: 36).strokeBorder(ShellPalette.popoverBorder, lineWidth: 1))
        .onAppear { controls.refresh() }.onExitCommand(perform: dismiss)
    }
    private var top: some View {
        HStack(spacing: 12) {
            if let battery = status.battery, let percent = status.batteryPercent {
                Button(action: run(actions.batterySettings)) {
                    HStack(spacing: 6) { AdwaitaIcon(name: StatusIcons.battery(percent: percent, charging: status.charging), fallback: "battery.100"); Text(battery).font(.adwaita(14.667, .bold)) }.padding(.horizontal, 12).frame(height: 38)
                }.buttonStyle(QuickRoundStyle()).accessibilityLabel("Battery, \(battery)")
            }
            round("applets-screenshooter-symbolic", "camera.viewfinder", "Take Screenshot") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")) }
            round("emblem-system-symbolic", "gearshape", "Settings", actions.systemSettings)
            Spacer(minLength: 0)
            round("system-lock-screen-symbolic", "lock", "Lock Screen", actions.lock)
            Button { open("power") } label: { AdwaitaIcon(name: "system-shutdown-symbolic", fallback: "power").frame(width: 38, height: 38) }
                .buttonStyle(QuickRoundStyle(on: section == "power")).help("Power Off / Log Out").accessibilityLabel("Power Off / Log Out").accessibilityValue(section == "power" ? "Expanded" : "Collapsed")
        }
    }
    private func round(_ icon: String, _ fallback: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: run(action)) { AdwaitaIcon(name: icon, fallback: fallback).frame(width: 38, height: 38) }.buttonStyle(QuickRoundStyle()).help(label).accessibilityLabel(label)
    }
    private var power: some View {
        QuickMenu(icon: "system-shutdown-symbolic", fallback: "power", title: "Power Off") {
            ForEach(SessionAction.allCases, id: \.self) { action in QuickMenuRow(title: action.menuTitle, action: run { endSession(action) }) }
        }
    }
    private var sliders: some View {
        VStack(spacing: 12) {
            if let volume = status.volume {
                QuickSlider(icon: StatusIcons.volume(level: volume.level, muted: volume.muted), fallback: "speaker.wave.2", label: "Volume", value: volume.muted ? 0 : volume.level,
                            iconAction: { status.setMuted(!volume.muted) }) { status.setVolume($0) }
            }
            if let brightness = controls.brightness {
                QuickSlider(icon: "display-brightness-symbolic", fallback: "sun.max", label: "Brightness", value: brightness) { controls.setBrightness($0) }
            }
        }
    }
    @ViewBuilder private var network: some View {
        if status.online && !status.wifi && controls.wifiOn != true {
            QuickToggle(icon: "network-wired-symbolic", fallback: "network", title: "Wired", subtitle: "Connected", on: true, menu: run(actions.networkSettings)) { }
        } else {
            let on = controls.wifiOn ?? false
            QuickToggle(icon: !on ? "network-wireless-disabled-symbolic" : status.online && status.wifi ? StatusIcons.network(available: true, wifi: true, rssi: status.rssi) : "network-wireless-signal-none-symbolic", fallback: "wifi", title: "Wi-Fi",
                        subtitle: !on ? nil : status.online && status.wifi ? "Connected" : "Not Connected", on: on, enabled: controls.wifiOn != nil, menu: run(actions.networkSettings)) { controls.setWifi(!on) }
        }
    }
    private var bluetooth: some View {
        let on = controls.bluetoothOn ?? false
        return QuickToggle(icon: on ? "bluetooth-active-symbolic" : "bluetooth-disabled-symbolic", fallback: "dot.radiowaves.left.and.right", title: "Bluetooth", on: on, enabled: controls.bluetoothOn != nil,
                           menu: run { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) }) { controls.setBluetooth(!on) }
    }
    private var mnome: some View {
        QuickMenu(icon: "mnome-symbolic", fallback: "gearshape.2", title: "Mnome") {
            QuickMenuRow(title: "Preferences", action: run(actions.preferences))
            QuickMenuRow(title: "Keyboard Shortcuts", action: run(actions.shortcuts))
            QuickMenuRow(title: "Top Bar", check: topBarOn, action: actions.toggleTopBar)
            QuickMenuRow(title: "Dock", check: dockOn, action: actions.toggleDock)
            QuickMenuRow(title: "Hide the Mac Menu Bar and Dock", check: !macChrome.hidden.isEmpty, action: actions.toggleMacChrome)
            QuickMenuRow(title: "Bring Back All Windows", action: run(actions.bringBackWindows))
            Divider().overlay(ShellPalette.ink(0.1)).padding(.vertical, 3)
            Text("Activities shortcut").font(.adwaita(13, .bold)).foregroundStyle(ShellPalette.dim).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(ShortcutChoice.all, id: \.title) { choice in QuickMenuRow(title: choice.title, check: model.shortcutTitle == choice.title) { actions.setShortcut(choice) } }
            if !dock.favorites.isEmpty {
                Divider().overlay(ShellPalette.ink(0.1)).padding(.vertical, 3)
                Text("Favorites").font(.adwaita(13, .bold)).foregroundStyle(ShellPalette.dim).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(dock.favorites) { favorite in QuickMenuRow(title: "Remove \(favorite.name)", action: { actions.removeFavorite(favorite.id) }) }
            }
            Divider().overlay(ShellPalette.ink(0.1)).padding(.vertical, 3)
            QuickMenuRow(title: "About Mnome", action: run(actions.about))
            QuickMenuRow(title: "Quit Mnome", action: run(actions.quit))
        }
    }
}

/// The 38 px round buttons of the top row (`.icon-button`), 10% ink, 28% when its menu is open.
struct QuickRoundStyle: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View { QuickRoundBody(configuration: configuration, on: on) }
}
private struct QuickRoundBody: View {
    let configuration: ButtonStyleConfiguration
    let on: Bool
    @State private var hover = false
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        configuration.label.background(Capsule().fill(ShellPalette.ink(configuration.isPressed || on ? 0.28 : hover ? 0.17 : 0.1)))
            .overlay(Capsule().stroke(contrast == .increased ? ShellPalette.ink(0.6) : .clear, lineWidth: 1))
            .contentShape(Capsule()).onHover { hover = $0 }.animation(.easeOut(duration: 0.1), value: hover)
    }
}
/// A quick toggle: a 48 px pill, the accent when on, with an arrow part when it has a menu.
struct QuickToggle: View {
    let icon: String, fallback: String, title: String
    var subtitle: String? = nil
    var on = false, enabled = true, open = false
    var menu: (() -> Void)? = nil
    let action: () -> Void
    @State private var hover = false
    private var fill: Color { on ? ShellPalette.toggleOn : ShellPalette.ink(hover ? 0.17 : 0.1) }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    AdwaitaIcon(name: icon, fallback: fallback)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.adwaita(14.667, .bold)).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.adwaita(12)).lineLimit(1).opacity(0.8) }
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 15).padding(.trailing, menu == nil ? 15 : 8).frame(maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title).accessibilityValue(menu == nil || on ? (on ? "On" : "Off") : "").accessibilityAddTraits(on ? .isSelected : [])
            if let menu {
                Rectangle().fill(on ? Color.white.opacity(0.25) : ShellPalette.ink(0.1)).frame(width: 1).padding(.vertical, 0)
                Button(action: menu) { AdwaitaIcon(name: open ? "pan-down-symbolic" : "pan-end-symbolic", fallback: open ? "chevron.down" : "chevron.right").frame(width: 38).frame(maxHeight: .infinity).background(on ? Color.white.opacity(0.1) : .clear).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("\(title) options")
            }
        }
        .foregroundStyle(on ? Color.white : ShellPalette.text).frame(height: 48).frame(maxWidth: .infinity)
        .background(fill).clipShape(Capsule()).opacity(enabled ? 1 : 0.5).onHover { hover = $0 }
    }
}
/// GNOME's slider: 4 px track at 10%, the accent up to the value, a 16 px handle.
struct QuickSlider: View {
    let icon: String, fallback: String, label: String
    let value: Double
    var iconAction: (() -> Void)? = nil
    let change: (Double) -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button { iconAction?() } label: { AdwaitaIcon(name: icon, fallback: fallback).frame(width: 32, height: 32) }.buttonStyle(ShellButtonStyle()).disabled(iconAction == nil).accessibilityLabel(iconAction == nil ? label : "Mute")
            GeometryReader { geometry in
                let width = geometry.size.width - 16, x = 8 + width * value
                ZStack(alignment: .leading) {
                    Capsule().fill(ShellPalette.ink(0.1)).frame(height: 4).padding(.horizontal, 8)
                    Capsule().fill(ShellPalette.toggleOn).frame(width: max(0, x - 8), height: 4).offset(x: 8)
                    Circle().fill(Color(white: 0.91)).shadow(color: .black.opacity(0.3), radius: 1, y: 1).frame(width: 16, height: 16).offset(x: x - 8)
                }.frame(maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { change(min(1, max(0, ($0.location.x - 8) / width))) })
            }.frame(height: 32)
            .accessibilityElement().accessibilityLabel(label).accessibilityValue("\(Int((value * 100).rounded()))%")
            .accessibilityAdjustableAction { change(MediaKey.step(value, up: $0 == .increment)) }
        }.padding(.horizontal, 4)
    }
}
/// A menu that opens inside quick settings (`.quick-toggle-menu`): 9% lighter, radius 24, a round icon header.
struct QuickMenu<Content: View>: View {
    let icon: String, fallback: String, title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                AdwaitaIcon(name: icon, fallback: fallback, size: 24).padding(9).background(Circle().fill(ShellPalette.ink(0.1)))
                Text(title).font(.adwaita(18, .bold))
            }.padding(.bottom, 9)
            content
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(ShellPalette.card).clipShape(RoundedRectangle(cornerRadius: 24))
    }
}
struct QuickMenuRow: View {
    let title: String
    var check: Bool? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack { Text(title).font(.adwaita(14.667)); Spacer(); if check == true { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) } }
                .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(ShellButtonStyle(radius: 12)).accessibilityAddTraits(check == true ? .isSelected : [])
    }
}

/// GNOME's end-session dialog: it acts by itself when the countdown ends, unless cancelled.
struct EndSessionView: View {
    let action: SessionAction
    let cancel: () -> Void
    let confirm: () -> Void
    @State private var left = SessionAction.countdown
    @State private var timer: Timer?
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text(action.title).font(.adwaita(20, .heavy))
                Text(action.message(seconds: left)).font(.adwaita(14.667)).multilineTextAlignment(.center).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }.padding(24).frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                Button("Cancel") { stop(); cancel() }.keyboardShortcut(.cancelAction).buttonStyle(DialogButtonStyle())
                Button(action.title) { stop(); confirm() }.keyboardShortcut(.defaultAction).buttonStyle(DialogButtonStyle(destructive: true))
            }.padding([.horizontal, .bottom], 24)
        }
        .frame(width: 420).background(ShellPalette.popover).clipShape(RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(ShellPalette.popoverBorder, lineWidth: 1))
        .onAppear { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in left -= 1; if left <= 0 { stop(); confirm() } } } }
        .onDisappear(perform: stop).onExitCommand { stop(); cancel() }
        .accessibilityElement(children: .contain).accessibilityLabel(action.title)
    }
    private func stop() { timer?.invalidate(); timer = nil }
}
struct DialogButtonStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.adwaita(14.667, .bold)).frame(maxWidth: .infinity).frame(height: 40)
            .foregroundStyle(destructive ? Color.white : ShellPalette.text)
            .background(Capsule().fill(destructive ? ShellPalette.destructive.opacity(configuration.isPressed ? 0.8 : 1) : ShellPalette.ink(configuration.isPressed ? 0.28 : 0.1)))
    }
}
