import AppKit
import ApplicationServices

/// The front app's menus in Mnome's bar, as GNOME 3's app menu beside Activities. The titles are read from the app's
/// own (hidden) Mac menu bar, and a click presses the real one: the app's menu opens as on the Mac, nothing is copied.
@MainActor final class AppMenus {
    struct Item: Equatable { let title: String; let frame: CGRect } // top-left coordinates, as Accessibility gives them
    struct Bar: Equatable { var pid: pid_t = 0; var items: [Item] = [] }
    private let status: BarStatus
    private var elements: [AXUIElement] = [], observers: [NSObjectProtocol] = []
    /// The last press, so a click is one press: the pointer moving while the button is down asks again.
    private var lastPress: (index: Int, at: Date)?, pressing = false
    init(status: BarStatus) { self.status = status }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        // shortcut: read again on app and Space changes only; a window moved to another display keeps its titles where they were until then.
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.read() } })
        }
        read()
    }
    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); observers = []
        elements = []; status.appMenus = Bar()
    }

    /// The Apple menu is left out: GNOME has none, and Quick Settings has lock, power and settings.
    private func read() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { elements = []; status.appMenus = Bar(); return }
        let pid = app.processIdentifier
        Task {
            let read = await AXClient.shared.run(pid) { () -> [(AXUIElement, Item)] in
                guard let bar = try AXUIElementCreateApplication(pid).value("AXMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
                let items = try (bar as! AXUIElement).value("AXChildren") as? [AXUIElement] ?? []
                return items.dropFirst().compactMap { item in
                    guard let title = try? item.value("AXTitle") as? String, !title.isEmpty, let frame = try? item.frame(), frame.width > 0 else { return nil }
                    return (item, Item(title: title, frame: frame))
                }
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return } // another app came in front meanwhile
            let found = (try? read.get()) ?? []
            elements = found.map(\.0)
            let bar = Bar(pid: pid, items: found.map(\.1))
            if status.appMenus != bar { status.appMenus = bar }
        }
    }

    /// Presses the real title, so the app opens its own menu where the Mac would: under Mnome's title. A title whose
    /// menu is open closes it instead, as a second click on the Mac does.
    func open(_ index: Int) {
        let pid = status.appMenus.pid
        guard elements.indices.contains(index), pid != 0, !pressing else { return }
        if let last = lastPress, last.index == index, Date().timeIntervalSince(last.at) < 0.4 { return }
        lastPress = (index, Date()); pressing = true
        let element = elements[index]
        Task {
            let done = await AXClient.shared.run(pid, urgent: true) {
                if try element.flag("AXSelected"), let menu = (try element.value("AXChildren") as? [AXUIElement])?.first { try menu.perform("AXCancel") } else { try element.perform("AXPress") }
            }
            pressing = false
            if case .failure = done { read() } // the app rebuilt its menus
        }
    }
}
