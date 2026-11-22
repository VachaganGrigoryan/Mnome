import AppKit
import SwiftUI

/// Renders shell surfaces with fixed data to PNG at the size of the GNOME reference pictures, without showing a window.
@MainActor enum Gallery {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let status = BarStatus(); status.clock = "Nov 4  3:15 PM"; status.battery = "80%"; status.batteryPercent = 80; status.network = "Connected by Wi-Fi"
        let model = Model(), dock = DockModel(), chrome = MacChromeController()
        dock.items = ["/System/Applications/Calendar.app", "/System/Applications/Mail.app", "/System/Applications/Notes.app", "/System/Applications/Utilities/Terminal.app"].enumerated().map { index, path in
            DockItem(id: path, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, url: URL(fileURLWithPath: path), pinned: index < 3, running: index > 1)
        }
        try save(TopBarView(status: status, model: model, dock: dock, macChrome: chrome, activities: {}, actions: QuickActions()), CGSize(width: 1280, height: 32), "top-bar", directory)
        try save(QuickSettingsView(status: status, model: model, dock: dock, macChrome: chrome, actions: QuickActions(), dismiss: {}).shellTheme(), nil, "quick-settings", directory)
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
