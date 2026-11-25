import AppKit
import MnomeSupport

/// Watches for extra Mac desktops (Spaces) and helps remove them: Mission Control is the only place that can,
/// so it comes back for as long as that takes.
@MainActor final class SpacesWatch: ObservableObject {
    static let shared = SpacesWatch()
    /// Displays with more than one Mac desktop, by name, and how many.
    @Published private(set) var extra: [String: Int] = [:]
    @Published private(set) var removing = false
    var macChrome: MacChromeController?
    private var observers: [NSObjectProtocol] = [], watch: Task<Void, Never>?

    func start() {
        check()
        observers = [NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.check() } },
                     NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }]
    }
    func check() { extra = Private.managedSpaces.map(MacSpaces.extra) ?? [:] }
    var summary: String? {
        guard let most = extra.values.max() else { return nil }
        return extra.count == 1 ? "A display has \(most) Mac desktops. Mnome manages only the one you are on." : "\(extra.count) displays have several Mac desktops. Mnome manages only the one you are on, on each."
    }
    /// Mission Control back for now; off again once each display has one desktop, or after five minutes.
    func remove() {
        guard !removing, let macChrome else { return }
        let wasHidden = macChrome.hidden.contains(.missionControl)
        removing = true
        if wasHidden { macChrome.set(.missionControl, hidden: false) }
        watch = Task {
            try? await Task.sleep(for: .seconds(1.5)) // the Dock restarts with Mission Control
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            let end = Date().addingTimeInterval(300)
            while Date() < end, !Task.isCancelled { try? await Task.sleep(for: .seconds(2)); check(); if extra.isEmpty { break } }
            if wasHidden { macChrome.set(.missionControl, hidden: true) }
            removing = false
        }
    }
}
