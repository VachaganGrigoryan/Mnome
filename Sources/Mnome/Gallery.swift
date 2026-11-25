import AppKit
import SwiftUI
import MnomeSupport

/// Renders shell surfaces with fixed data to PNG at the size of the GNOME reference pictures, without showing a window.
@MainActor enum Gallery {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); Adwaita.registerFont()
        let status = BarStatus(); status.clock = "Nov 4  3:15 PM"; status.battery = "80%"; status.batteryPercent = 80; status.network = "Connected by Wi-Fi"
        let model = Model(), dock = DockModel(), chrome = MacChromeController()
        dock.items = ["/System/Applications/Calendar.app", "/System/Applications/Mail.app", "/System/Applications/Notes.app", "/System/Applications/Utilities/Terminal.app"].enumerated().map { index, path in
            DockItem(id: path, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, url: URL(fileURLWithPath: path), pinned: index < 3, running: index > 1)
        }
        let reference = BarStatus() // as `gnome-ref/shell/002-desktop-with-console.png`: wired, muted, no battery, two workspaces
        reference.clock = StatusText.clock(Date(timeIntervalSince1970: 26_579_700), locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)
        reference.network = "Ethernet connected"; reference.volume = (0.5, true); reference.workspaces = BarWorkspaces(count: 2, current: 0, on: true)
        let settings = AppearanceSettings.shared, chosen = settings.choice
        defer { settings.choice = chosen }
        for (choice, name) in [("Dark", "top-bar"), ("Light", "top-bar-light")] {
            settings.choice = choice
            try save(TopBarView(status: reference, model: model, dock: dock, macChrome: chrome, activities: {}, actions: QuickActions()), CGSize(width: 1280, height: 32), name, directory)
        }
        settings.choice = "Dark"
        try save(DateMenuView(agenda: Agenda(preview: true), at: Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 15, minute: 15))).shellTheme(follows: true), nil, "date-menu", directory)
        status.volume = (0, true); status.online = true; status.wifi = false
        try save(QuickSettingsView(status: status, controls: SystemControls(), model: model, dock: dock, macChrome: chrome, actions: QuickActions(), dismiss: {}).shellTheme(follows: true), nil, "quick-settings", directory)
        try save(RunDialogView(close: {}).shellTheme(follows: true), nil, "run-dialog", directory)
        try save(EndSessionView(action: .restart, cancel: {}, confirm: {}).shellTheme(follows: true), nil, "end-session", directory)
        try save(ScrollView { VStack(alignment: .leading, spacing: 20) { KeyboardPreferences() }.padding(24) }.mnomeTheme().background(ThemePalette.background), CGSize(width: 560, height: 1500), "preferences-keyboard", directory)
        try save(ShortcutsView().mnomeTheme().background(ThemePalette.background), CGSize(width: 520, height: 1100), "shortcuts", directory)
        try save(DockView(model: dock), CGSize(width: 440, height: 80), "dash", directory)
    }
    private static func save(_ view: some View, _ size: CGSize?, _ name: String, _ directory: URL) throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size ?? host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua); window.isReleasedWhenClosed = false; window.contentView = host
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)) // SwiftUI lays out scroll content on the next turn
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
