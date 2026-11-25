import AppKit
import SwiftUI
import CoreText

/// GNOME's font and symbolic icons, bundled from adwaita-fonts and adwaita-icon-theme (`Resources/ADWAITA-PROVENANCE.md`).
@MainActor enum Adwaita {
    static let family = "Adwaita Sans"
    private(set) static var fontReady = false
    private static var icons: [String: NSImage] = [:]
    /// Process-wide only: nothing is installed for the person.
    static func registerFont() {
        guard !fontReady else { return }
        if let url = Bundle.module.url(forResource: "AdwaitaSans-Regular", withExtension: "ttf") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        fontReady = NSFont(name: family, size: 12) != nil
    }
    static func icon(_ name: String) -> NSImage? {
        if let cached = icons[name] { return cached }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true; icons[name] = image; return image
    }
}
extension Font {
    /// GNOME sizes are in px at 96 dpi, kept as points; the system font stands in if registration failed.
    @MainActor static func adwaita(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Adwaita.fontReady ? .custom(Adwaita.family, fixedSize: size).weight(weight) : .system(size: size, weight: weight)
    }
}
/// A 16 px symbolic icon in the current foreground colour, or an SF Symbol when the SVG is missing.
struct AdwaitaIcon: View {
    let name: String, fallback: String
    var size: CGFloat = 16
    var body: some View {
        if let image = Adwaita.icon(name) { Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high).frame(width: size, height: size) }
        else { Image(systemName: fallback).font(.system(size: size * 0.85)).frame(width: size, height: size) }
    }
}
