import AppKit
import SwiftUI
import MnomeSupport

@MainActor final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()
    @Published var choice: String { didSet { UserDefaults.standard.set(choice, forKey: "appearance") } }
    init() { choice = AppearanceChoice.saved(UserDefaults.standard.string(forKey: "appearance")).rawValue }
    var scheme: ColorScheme? { choice == "Dark" ? .dark : choice == "Light" ? .light : nil }
}

private func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: alpha)
}
private func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
}

/// libadwaita named colors (light / dark variants).
enum ThemePalette {
    static let accent = adaptive(hex(0x3584e4), hex(0x3584e4))
    static let accentText = adaptive(hex(0x1c71d8), hex(0x78aeed))
    static let background = adaptive(hex(0xfafafa), hex(0x242424)) // window_bg_color
    static let view = adaptive(hex(0xffffff), hex(0x1e1e1e))
    static let surface = adaptive(hex(0xffffff), NSColor(white: 1, alpha: 0.08)) // card_bg_color
    static let headerbar = adaptive(hex(0xebebeb), hex(0x303030))
    static let destructive = adaptive(hex(0xe01b24), hex(0xc01c28))
    static let success = adaptive(hex(0x2ec27e), hex(0x26a269))
    static let border = adaptive(NSColor(white: 0, alpha: 0.15), NSColor(white: 1, alpha: 0.15))
    static let foreground = Color.primary
    static let dim = Color.primary.opacity(0.55)
}

/// GNOME Shell surfaces are always dark, whatever the Appearance choice.
enum ShellPalette {
    static let panel = Color.black
    static let overview = Color(nsColor: hex(0x1e1e1e, 0.95))
    static let dash = Color(nsColor: hex(0x2e2e33, 0.92))
    static let popover = Color(nsColor: hex(0x2a2a2a))
    static let toggle = Color.white.opacity(0.10)
    static let toggleOn = Color(nsColor: hex(0x3584e4))
    static let hover = Color.white.opacity(0.10)
    static let pressed = Color.white.opacity(0.17)
    static let dim = Color.white.opacity(0.6)
    static let destructive = Color(nsColor: hex(0xc01c28))
}

struct MnomeTheme: ViewModifier {
    @ObservedObject var settings = AppearanceSettings.shared
    func body(content: Content) -> some View { content.preferredColorScheme(settings.scheme).tint(ThemePalette.accent) }
}
struct ShellTheme: ViewModifier {
    func body(content: Content) -> some View { content.preferredColorScheme(.dark).tint(ShellPalette.toggleOn).foregroundStyle(.white) }
}
extension View {
    func mnomeTheme() -> some View { modifier(MnomeTheme()) }
    func shellTheme() -> some View { modifier(ShellTheme()) }
}

// MARK: Buttons

enum AdwaitaButtonKind { case normal, flat, suggested, destructive, pill, circular }
struct AdwaitaButtonStyle: ButtonStyle {
    var kind: AdwaitaButtonKind = .normal
    init(_ kind: AdwaitaButtonKind = .normal) { self.kind = kind }
    func makeBody(configuration: Configuration) -> some View { AdwaitaButtonBody(configuration: configuration, kind: kind) }
}
private struct AdwaitaButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: AdwaitaButtonKind
    @State private var hover = false
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    private var radius: CGFloat { kind == .pill || kind == .circular ? 999 : 6 }
    private var fill: Color {
        let level = configuration.isPressed ? 2 : hover ? 1 : 0
        switch kind {
        case .suggested: return ThemePalette.accent.opacity([1, 0.9, 0.75][level])
        case .destructive: return ThemePalette.destructive.opacity([1, 0.9, 0.75][level])
        case .flat: return Color.primary.opacity([0, 0.08, 0.16][level])
        default: return Color.primary.opacity([0.07, 0.11, 0.18][level])
        }
    }
    var body: some View {
        configuration.label
            .padding(.horizontal, kind == .circular ? 0 : 10).padding(.vertical, kind == .circular ? 0 : 5)
            .foregroundStyle(kind == .suggested || kind == .destructive ? Color.white : Color.primary)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(focused ? ThemePalette.accent : contrast == .increased ? Color.primary : Color.clear, lineWidth: focused ? 2 : 1))
            .opacity(enabled ? 1 : 0.5).onHover { hover = $0 }
    }
}
/// Panel / dash buttons: transparent at rest, highlight on hover and press.
struct ShellButtonStyle: ButtonStyle {
    var radius: CGFloat = 999
    func makeBody(configuration: Configuration) -> some View { ShellButtonBody(configuration: configuration, radius: radius) }
}
private struct ShellButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let radius: CGFloat
    @State private var hover = false
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        configuration.label
            .background(configuration.isPressed ? ShellPalette.pressed : hover ? ShellPalette.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(focused ? ShellPalette.toggleOn : contrast == .increased ? Color.white.opacity(0.6) : Color.clear, lineWidth: 2))
            .opacity(enabled ? 1 : 0.5).onHover { hover = $0 }
    }
}
/// Quick Settings toggle pill.
struct QuickToggleStyle: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).padding(.vertical, 8)
            .background((on ? ShellPalette.toggleOn : ShellPalette.toggle).opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 999))
            .overlay(RoundedRectangle(cornerRadius: 999).stroke(Color.white.opacity(0.0), lineWidth: 1))
    }
}

// MARK: Boxed lists (AdwPreferencesGroup / AdwActionRow family)

struct PreferencesGroup<Content: View>: View {
    let title: String?; var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.headline).padding(.leading, 4) }
            BoxedList { content }
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.leading, 4) }
        }
    }
}
struct BoxedList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { _VariadicView.Tree(DividedLayout()) { content } }
            .background(ThemePalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ThemePalette.border, lineWidth: 1))
    }
}
private struct DividedLayout: _VariadicView_MultiViewRoot {
    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last { Divider().padding(.leading, 12) }
        }
    }
}
struct ActionRow<Trailing: View>: View {
    let title: String; var subtitle: String? = nil; var icon: String? = nil
    var showsChevron = false
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        let row = HStack(spacing: 12) {
            if let icon { Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing
            if showsChevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 44).contentShape(Rectangle())
        if let action {
            Button(action: action) { row }.buttonStyle(AdwaitaButtonStyle(.flat)).accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        } else { row.accessibilityElement(children: .combine) }
    }
}
extension ActionRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, icon: String? = nil, showsChevron: Bool = false, action: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, icon: icon, showsChevron: showsChevron, action: action) { EmptyView() }
    }
}
struct SwitchRow: View {
    let title: String; var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        ActionRow(title: title, subtitle: subtitle) { Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden() }
    }
}
/// Radio-style row (AdwActionRow + checkmark suffix).
struct CheckRow: View {
    let title: String; let selected: Bool; let action: () -> Void
    var body: some View {
        ActionRow(title: title, action: action) {
            Image(systemName: "checkmark").foregroundStyle(ThemePalette.accentText).opacity(selected ? 1 : 0)
        }.accessibilityValue(selected ? "Selected" : "Not selected").accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct ExpanderRow<Content: View>: View {
    let title: String; var subtitle: String? = nil; var icon: String? = nil
    @State private var expanded = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            ActionRow(title: title, subtitle: subtitle, icon: icon, action: { expanded.toggle() }) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }.accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { Divider(); content }
        }
    }
}
struct StatusPage: View {
    let icon: String; let title: String; var detail: String? = nil
    var actionTitle: String? = nil; var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 56, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.title2.bold())
            if let detail { Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(AdwaitaButtonStyle(.suggested)).padding(.top, 8) }
        }.padding(24).frame(maxWidth: .infinity)
    }
}
struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(.caption, design: .monospaced).weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(ThemePalette.border, lineWidth: 1))
    }
}

// MARK: Header bars (AdwHeaderBar / AdwViewSwitcher)

struct HeaderBar<Center: View>: View {
    @ViewBuilder var center: Center
    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 70, height: 1) // room for the window buttons
            Spacer(minLength: 0)
            center
            Spacer(minLength: 0)
            PrimaryMenu()
        }.padding(.horizontal, 10).frame(height: 47).background(ThemePalette.headerbar).overlay(alignment: .bottom) { Rectangle().fill(ThemePalette.border).frame(height: 1) }
    }
}
extension HeaderBar where Center == Text {
    init(title: String) { self.init { Text(title).font(.headline) } }
}
/// HIG primary menu: Preferences, Keyboard Shortcuts, About.
struct PrimaryMenu: View {
    var body: some View {
        Menu {
            Button("Preferences") { ShellUtilities.shared.showPreferences() }
            Button("Keyboard Shortcuts") { ShellUtilities.shared.showShortcuts() }
            Button("About Mnome") { ShellUtilities.shared.showAbout() }
        } label: { Image(systemName: "line.3.horizontal").frame(width: 28, height: 28) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Main Menu")
    }
}
struct ViewSwitcher: View {
    @Binding var selection: String
    let pages: [(id: String, title: String, icon: String)]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(pages, id: \.id) { page in
                Button { selection = page.id } label: {
                    Label(page.title, systemImage: page.icon).labelStyle(.titleAndIcon).font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 5)
                        .background(selection == page.id ? Color.primary.opacity(0.14) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(AdwaitaButtonStyle(.flat)).accessibilityAddTraits(selection == page.id ? .isSelected : [])
            }
        }
    }
}

// MARK: Utility windows (libadwaita-style)

@MainActor final class ShellUtilities {
    static let shared = ShellUtilities()
    private var windows: [String: NSWindow] = [:]
    private var actions = QuickActions()
    private var model: Model?
    private var dock: DockModel?
    private var macChrome: MacChromeController?
    func configure(actions: QuickActions, model: Model, dock: DockModel, macChrome: MacChromeController) { self.actions = actions; self.model = model; self.dock = dock; self.macChrome = macChrome }
    func showPreferences() {
        guard let model, let dock, let macChrome else { return }
        show("Preferences", size: NSSize(width: 560, height: 600), view: AnyView(PreferencesView(model: model, dock: dock, macChrome: macChrome, actions: actions)))
    }
    func showShortcuts() { show("Keyboard Shortcuts", size: NSSize(width: 520, height: 640), view: AnyView(ShortcutsView())) }
    func showAbout() { show("About Mnome", size: NSSize(width: 360, height: 460), view: AnyView(AboutView())) }
    private func show(_ title: String, size: NSSize, view: AnyView) {
        if let window = windows[title] { NSApp.activate(); window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: view.ignoresSafeArea().background(ThemePalette.background).mnomeTheme()); windows[title] = window
        window.center(); NSApp.activate(); window.makeKeyAndOrderFront(nil)
    }
}
struct PreferencesView: View {
    @ObservedObject var settings = AppearanceSettings.shared
    @ObservedObject var model: Model
    @ObservedObject var dock: DockModel
    @ObservedObject var macChrome: MacChromeController
    let actions: QuickActions
    @AppStorage("showTopBar") private var topBarOn = true
    @AppStorage("showDock") private var dockOn = true
    @State private var page = "appearance"
    var body: some View {
        VStack(spacing: 0) {
            HeaderBar { ViewSwitcher(selection: $page, pages: [("appearance", "Appearance", "paintbrush"), ("shell", "Shell", "menubar.rectangle"), ("dash", "Dash", "dock.rectangle")]) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch page {
                    case "shell":
                        PreferencesGroup(title: "Panels") {
                            SwitchRow(title: "Show Top Bar", isOn: Binding(get: { topBarOn }, set: { _ in actions.toggleTopBar() }))
                            SwitchRow(title: "Show Dock", isOn: Binding(get: { dockOn }, set: { _ in actions.toggleDock() }))
                        }
                        PreferencesGroup(title: "macOS", footer: "Original settings are saved and restored automatically when Mnome quits. If Mnome ever quits unexpectedly, relaunch it and use Restore All.") {
                            ForEach(MacElement.allCases, id: \.self) { element in
                                SwitchRow(title: element.title, isOn: Binding(get: { macChrome.hidden.contains(element) }, set: { macChrome.set(element, hidden: $0) }))
                            }
                            ActionRow(title: "Restore All macOS Settings", icon: "arrow.uturn.backward", action: { macChrome.restoreAll() }).disabled(!macChrome.needsRestore)
                        }
                        PreferencesGroup(title: "Overview Shortcut", footer: "System-reserved shortcuts remain controlled by macOS.") {
                            ForEach(ShortcutChoice.all, id: \.title) { choice in
                                CheckRow(title: choice.title, selected: model.shortcutTitle == choice.title) { actions.setShortcut(choice) }
                            }
                        }
                    case "dash":
                        if dock.favorites.isEmpty { StatusPage(icon: "star", title: "No Favorites", detail: "Pin applications to the dash from the launcher.") }
                        else {
                            PreferencesGroup(title: "Favorites", footer: "Drag icons in the dash, or use their context menu, to reorder.") {
                                ForEach(dock.favorites) { favorite in
                                    ActionRow(title: favorite.name, subtitle: dock.resolved(favorite) == nil ? "Unavailable" : nil) {
                                        Button { actions.removeFavorite(favorite.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(AdwaitaButtonStyle(.flat))
                                            .help("Remove \(favorite.name)").accessibilityLabel("Remove \(favorite.name) from favorites")
                                    }
                                }
                            }
                        }
                    default:
                        PreferencesGroup(title: "Appearance", footer: "Applies to Mnome windows. Shell surfaces stay dark, like GNOME Shell. Follows the GNOME Human Interface Guidelines, adapted to macOS accessibility and system services.") {
                            ForEach(AppearanceChoice.allCases, id: \.rawValue) { choice in
                                CheckRow(title: choice.rawValue, selected: settings.choice == choice.rawValue) { settings.choice = choice.rawValue }
                            }
                        }
                    }
                }.padding(24)
            }
        }
    }
}
struct ShortcutsView: View {
    private let groups: [(String, [(String, String)])] = [
        ("Shell", [("Find applications and windows", "Ctrl+F"), ("Refresh", "Ctrl+R"), ("Close current surface", "Ctrl+W"), ("Quit Mnome", "Ctrl+Q"), ("Preferences", "Ctrl+,"), ("Keyboard shortcuts", "Ctrl+?")]),
        ("Navigation", [("Move focus", "Tab / Shift+Tab"), ("Navigate items", "Arrow keys"), ("Activate focused item", "Return"), ("Clear search, then close", "Escape"), ("Item actions", "Shift+F10")]),
    ]
    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(title: "Keyboard Shortcuts")
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groups, id: \.0) { group in
                        PreferencesGroup(title: group.0) {
                            ForEach(group.1, id: \.0) { row in ActionRow(title: row.0) { Keycap(text: row.1) } }
                        }
                    }
                    Text("System-reserved shortcuts remain controlled by macOS. The global shell shortcut is configurable in Preferences.").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
        }
    }
}
struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(title: "About Mnome")
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128).accessibilityHidden(true)
                Text("Mnome").font(.largeTitle.bold())
                Text("A GNOME-inspired desktop shell for macOS.").foregroundStyle(.secondary)
                Text("0.1.0").font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 3)
                    .background(ThemePalette.accent.opacity(0.18)).foregroundStyle(ThemePalette.accentText).clipShape(Capsule())
                BoxedList { ActionRow(title: "Built with") { Text("Rust + Swift").foregroundStyle(.secondary) } }.padding(.top, 12)
            }.padding(32)
            Spacer(minLength: 0)
        }
    }
}
