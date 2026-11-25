import AppKit
import Combine
import MnomeSupport

/// GNOME's bar items in the Mac's own menu bar, when that is the bar (Preferences → Shell): Activities (the workspace
/// dots), the clock with the calendar, and the status pill with Quick Settings. The Mac's own status icons are hidden
/// meanwhile (`MacElement.statusIcons`); app icons stay, as GNOME's app indicators do.
@MainActor final class StatusItems {
    private let topBar: TopBarController
    private var activities: NSStatusItem?, clock: NSStatusItem?, pill: NSStatusItem?, watch: AnyCancellable?
    /// Mnome's own menu, on a right click on Activities.
    var menu: NSMenu?
    var toggleOverview: () -> Void = {}
    /// Only the date when the Mac's own clock would not hide, so the time is not there twice.
    var dateOnly = false { didSet { redraw() } }
    init(topBar: TopBarController) { self.topBar = topBar }

    func set(shown: Bool) {
        guard shown != (activities != nil) else { return }
        guard shown else {
            for item in [activities, clock, pill] { if let item { NSStatusBar.system.removeStatusItem(item) } }
            activities = nil; clock = nil; pill = nil; watch = nil; topBar.itemFrame = { _ in nil }; return
        }
        // Each new item goes left of the ones before it: the pill ends up rightmost, as in GNOME.
        pill = item("mnome.status", "System status and Mnome settings", #selector(openQuickSettings))
        clock = item("mnome.clock", "Date and time", #selector(openDateMenu))
        activities = item("mnome.activities", "Activities", #selector(activitiesClicked))
        for item in [pill, clock, activities] { item?.isVisible = true } // macOS remembers a hidden item by its name
        activities?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        topBar.itemFrame = { [weak self] kind in (kind == "date" ? self?.clock : self?.pill)?.button?.window?.frame }
        watch = topBar.status.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in DispatchQueue.main.async { self?.redraw() } }
        redraw()
    }
    private func item(_ name: String, _ label: String, _ action: Selector) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = name // keeps a place the person drags it to
        item.button?.target = self; item.button?.action = action; item.button?.setAccessibilityLabel(label)
        return item
    }
    @objc private func openQuickSettings() { if let frame = pill?.button?.window?.frame { topBar.toggleMenu("quick", under: frame) } }
    @objc private func openDateMenu() { if let frame = clock?.button?.window?.frame { topBar.toggleMenu("date", under: frame) } }
    @objc private func activitiesClicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp, let menu, let button = activities?.button else { toggleOverview(); return }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func redraw() {
        let status = topBar.status
        activities?.button?.image = Self.dots(status.workspaces)
        let text = dateOnly ? StatusText.date(Date()) : status.clock
        clock?.button?.attributedTitle = NSAttributedString(string: text, attributes: [.font: Self.font])
        var names = [StatusIcons.network(available: status.online, wifi: status.wifi, rssi: status.rssi)]
        if let volume = status.volume { names.append(StatusIcons.volume(level: volume.level, muted: volume.muted)) }
        names.append(status.batteryPercent.map { StatusIcons.battery(percent: $0, charging: status.charging) } ?? "system-shutdown-symbolic")
        pill?.button?.image = Self.joined(names.compactMap(Adwaita.icon))
        pill?.button?.toolTip = status.network
    }
    private static let font: NSFont = { guard Adwaita.fontReady, let font = NSFont(name: Adwaita.family, size: 13) else { return .boldSystemFont(ofSize: 13) }; return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }()
    /// GNOME's dots: the current workspace a wide pill, the others small dots, as one template image.
    private static func dots(_ workspaces: BarWorkspaces) -> NSImage {
        let dots = WorkspaceDots.dots(count: workspaces.count, current: workspaces.current, on: workspaces.on)
        let width = dots.reduce(0) { $0 + ($1 ? WorkspaceDots.active.width : WorkspaceDots.inactive.width) } + WorkspaceDots.spacing * CGFloat(dots.count - 1)
        let image = NSImage(size: CGSize(width: width, height: 16), flipped: false) { _ in
            var x: CGFloat = 0
            for current in dots {
                let size = current ? WorkspaceDots.active : WorkspaceDots.inactive
                NSColor.black.withAlphaComponent(current ? 1 : 0.5).setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: (16 - size.height) / 2, width: size.width, height: size.height), xRadius: size.height / 2, yRadius: size.height / 2).fill()
                x += size.width + WorkspaceDots.spacing
            }
            return true
        }
        image.isTemplate = true; return image
    }
    /// The pill's icons side by side, 16 points high and 8 apart, as one template image.
    private static func joined(_ icons: [NSImage]) -> NSImage {
        let side: CGFloat = 16, gap: CGFloat = 8, width = CGFloat(icons.count) * side + CGFloat(max(0, icons.count - 1)) * gap
        let image = NSImage(size: CGSize(width: max(side, width), height: side), flipped: false) { _ in
            for (i, icon) in icons.enumerated() { icon.draw(in: CGRect(x: CGFloat(i) * (side + gap), y: 0, width: side, height: side)) }
            return true
        }
        image.isTemplate = true; return image
    }
}
