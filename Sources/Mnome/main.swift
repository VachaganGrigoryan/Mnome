import AppKit
import SwiftUI
import ScreenCaptureKit
import Carbon
import Combine
import CMnome
import MnomeSupport

struct AppItem: Identifiable { let id: String; let name: String; let url: URL }
enum BridgeError: Error { case invalidRequest, invalidResponse, rejected(String) }
func coreResult(_ request: [String: Any]) -> Result<[String: Any], Error> {
    do { return .success(try coreChecked(request)) } catch { return .failure(error) }
}
func core(_ request: [String: Any]) -> [String: Any] { (try? coreChecked(request)) ?? ["ok": false, "error": "The core operation failed."] }
func coreChecked(_ request: [String: Any]) throws -> [String: Any] {
    guard let input = try? JSONSerialization.data(withJSONObject: request) else { throw BridgeError.invalidRequest }
    let output = input.withUnsafeBytes { mnome_request($0.bindMemory(to: UInt8.self).baseAddress, input.count) }
    defer { mnome_free(output) }
    guard let ptr = output.ptr, output.len > 0 else { throw BridgeError.invalidResponse }
    let data = Data(bytes: ptr, count: output.len)
    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.invalidResponse }; if response["ok"] as? Bool == false { throw BridgeError.rejected(response["error"] as? String ?? "Operation failed") }; return response
}
enum PresentationState: Equatable { case loading, content, empty, error(String) }
@MainActor final class Model: ObservableObject {
    @Published var query = ""; @Published var apps: [AppItem] = []
    @Published var filtered: [AppItem] = []
    @Published var appState: PresentationState = .loading
    @Published var shortcutTitle = "Control–Option–Space"
    /// The app grid's folders, saved as they change.
    @Published var folders: [AppFolder] = [] { didSet { if foldersLoaded { AppFolderStore().save(folders) }; updateEntries() } }
    /// The grid's top level: apps and folders by name.
    @Published private(set) var entries: [AppGridEntry] = []
    private var foldersLoaded = false, byPath: [String: AppItem] = [:]
    func item(_ path: String) -> AppItem? { byPath[path] }
    private func updateEntries() { entries = AppFolders.entries(apps: apps.map { ($0.id, $0.name) }, folders: folders) }
    /// Dropped on an app, the two make a folder; on a folder, it joins it.
    func drop(_ app: String, on target: AppGridEntry) {
        switch target {
        case let .app(other): folders = AppFolders.make(app, other, id: UUID().uuidString, in: folders)
        case let .folder(folder): folders = AppFolders.add(app, to: folder.id, in: folders)
        }
    }
    func removeFromFolder(_ app: String) { folders = AppFolders.remove(app, in: folders) }
    func renameFolder(_ id: String, to name: String) { folders = AppFolders.rename(id, to: name, in: folders) }
    var searchGeneration = UUID()
    func search() {
        searchGeneration = UUID(); let generation = searchGeneration
        appState = .loading
        let items = apps; let term = query
        DispatchQueue.global(qos: .userInitiated).async {
            let response = core(["version": 1, "op": "search", "query": term, "apps": items.map { ["id": $0.id, "name": $0.name] }])
            let results = response["apps"] as? [[String: Any]] ?? []
            let found = results.compactMap { result in items.first { $0.id == result["id"] as? String } }
            Task { @MainActor in if self.searchGeneration == generation { self.filtered = found; self.appState = response["ok"] as? Bool == false ? .error("Application search failed. Try refreshing.") : (found.isEmpty ? .empty : .content) } }
        }
    }
    func discover() {
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [String: AppItem] = [:]
            for path in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
                guard let iterator = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in iterator where url.pathExtension == "app" {
                    iterator.skipDescendants()
                    let bundle = Bundle(url: url)
                    let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
                    found[url.path] = AppItem(id: url.path, name: name, url: url)
                }
            }
            let items = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                self.apps = items; self.byPath = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                if !self.foldersLoaded { self.folders = AppFolderStore().load { AppFolders.seed(apps: items.map(\.id)) }; self.foldersLoaded = true } else { self.updateEntries() }
                self.search()
            }
        }
    }
}
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let topBar = TopBarController()
    let dock = DockController()
    let macChrome = MacChromeController()
    let windowManager = WindowManager()
    private var dragTiler: DragTiler?
    private let hotCorner = HotCornerWatch()
    private lazy var slide = WorkspaceSlide(manager: windowManager, captures: overview.captures, wallpapers: overview.wallpapers)
    private lazy var gestures = Gestures(overview: overview, slide: slide, manager: windowManager)
    private lazy var desktop = DesktopController(wallpapers: overview.wallpapers)
    private lazy var statusItems = StatusItems(topBar: topBar)
    private lazy var appMenus = AppMenus(status: topBar.status)
    private lazy var appIcons = AppIcons(status: topBar.status)
    let switcher = SwitcherController(), workspacePopup = WorkspacePopup()
    private var workspaceWatch: AnyCancellable?, mediaWatch: AnyCancellable?, screensWatch: NSObjectProtocol?
    let osd = OSD()
    let model = Model(), overview = OverviewController(); var status: NSStatusItem!; var hotkey: EventHotKeyRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOnSignals()
        NSApp.setActivationPolicy(.accessory); model.shortcutTitle = UserDefaults.standard.string(forKey: "shortcutTitle") ?? "Control–Option–Space"; model.discover()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.main.url(forResource: "Mnome", withExtension: "icns"), let appIcon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = appIcon
            let menuIcon = appIcon.copy() as! NSImage
            menuIcon.size = NSSize(width: 18, height: 18); menuIcon.isTemplate = true
            status.button?.image = menuIcon; status.button?.title = ""; status.button?.toolTip = "Mnome"
            status.button?.setAccessibilityLabel("Mnome")
        } else { status.button?.title = "Mnome" }
        let menu = NSMenu(); menu.addItem(withTitle: "Open Mnome", action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Mnome", action: #selector(quit), keyEquivalent: "q").target = self; let shortcuts = NSMenu()
        for choice in ShortcutChoice.all {
            let item = NSMenuItem(title: choice.title, action: #selector(changeShortcut(_:)), keyEquivalent: ""); item.tag = choice.mask; item.target = self; shortcuts.addItem(item)
        }
        let shortcutItem = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: ""); shortcutItem.submenu = shortcuts; menu.insertItem(shortcutItem, at: 1)
        let visibility = NSMenuItem(title: "Show Top Bar", action: #selector(toggleTopBar(_:)), keyEquivalent: "")
        visibility.target = self; visibility.state = topBar.enabled ? .on : .off; menu.insertItem(visibility, at: 1)
        let dockVisibility = NSMenuItem(title: "Show Dock", action: #selector(toggleDock(_:)), keyEquivalent: "")
        dockVisibility.target = self; dockVisibility.state = dock.enabled ? .on : .off; menu.insertItem(dockVisibility, at: 1)
        let favoritesItem = NSMenuItem(title: "Favorites", action: nil, keyEquivalent: ""); favoritesItem.submenu = NSMenu(); menu.insertItem(favoritesItem, at: 1)
        for (title, action) in [("Preferences…", #selector(showPreferences)), ("Keyboard Shortcuts", #selector(showKeyboardShortcuts)), ("About Mnome", #selector(showAbout)), ("Focus Dock", #selector(focusDock)), ("Focus Top Bar", #selector(focusTopBar)), ("Restore macOS Shell", #selector(restoreMacChrome)), ("Bring Back All Windows", #selector(bringBackWindows))] { let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; menu.addItem(item) }
        status.menu = menu
        dock.model.beforeOpen = { [weak self] in self?.overview.close() }
        dock.changed = { [weak self] in self?.updateFavoritesMenu() }
        dock.model.showApps = { [weak self] in self?.overview.toggle(apps: true) }
        OverviewController.restoreDockAfterCrash(); overview.usesMacDock = { [weak self] in self.map { !$0.macChrome.hidden.contains(.dock) } ?? false }
        overview.model = model; overview.windowManager = windowManager; overview.dock = dock.model; overview.topBar = topBar; overview.wallpapers.load()
        dock.start()
        updateFavoritesMenu()
        topBar.activities = { [weak self] in self?.showActivities() }
        topBar.model = model; topBar.dock = dock.model; topBar.macChrome = macChrome; topBar.appMenus = appMenus; topBar.appIcons = appIcons
        macChrome.changed = { [weak self] in self?.topBar.rebuild(); self?.dock.rebuild(); self?.windowManager.updateDisplays(); self?.updateDesktop() }
        desktop.showPreferences = { ShellUtilities.shared.showPreferences() }; updateDesktop()
        SpacesWatch.shared.macChrome = macChrome; SpacesWatch.shared.start()
        // The Show Applications tile in the Mac Dock.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.mnome.showApplications"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.overview.toggle(apps: true) } }
        topBar.actions = QuickActions(
            openMnome: { [weak self] in self?.showActivities() }, preferences: { [weak self] in self?.showPreferences() }, shortcuts: { [weak self] in self?.showKeyboardShortcuts() },
            about: { [weak self] in self?.showAbout() }, quit: { [weak self] in self?.quit() }, systemSettings: { [weak self] in self?.openSettings("") },
            networkSettings: { [weak self] in self?.openNetworkSettings() }, batterySettings: { [weak self] in self?.openBatterySettings() },
            lock: { [weak self] in self?.perform(.lock) }, focusDock: { [weak self] in self?.focusDock() }, focusTopBar: { [weak self] in self?.focusTopBar() }, setWorkspaces: { [weak self] in self?.windowManager.workspacesWanted = $0 },
            toggleTopBar: { [weak self] in self?.setTopBarVisible(!(self?.topBar.enabled ?? true)) }, toggleDock: { [weak self] in self?.setDockVisible(!(self?.dock.enabled ?? true)) },
            setShortcut: { [weak self] in self?.applyShortcut($0) }, removeFavorite: { [weak self] in self?.dock.model.remove($0) },
            toggleMacChrome: { [weak self] in guard let self else { return }; self.macChrome.setAll(hidden: self.macChrome.hidden.isEmpty) }, bringBackWindows: { [weak self] in self?.bringBackWindows() })
        ShellUtilities.shared.configure(actions: topBar.actions, model: model, dock: dock.model, macChrome: macChrome)
        Adwaita.registerFont(); macChrome.hideChosen(); topBar.start()
        statusItems.menu = status.menu; statusItems.toggleOverview = { [weak self] in self?.showActivities() }
        statusItems.set(shown: !topBar.enabled); statusItems.dateOnly = !topBar.enabled; status.isVisible = topBar.enabled // the Mac's clock keeps the time
        if topBar.enabled { appMenus.start(); appIcons.start() }
        workspaceWatch = windowManager.$state.sink { [weak self] state in
            guard let self, let state else { return }
            let now = BarWorkspaces(count: state.workspaces.count, current: state.workspaces.firstIndex(of: state.current) ?? 0, on: state.workspacesOn)
            if self.topBar.status.workspaces != now { self.topBar.status.workspaces = now }
        }
        windowManager.reserved = { [weak self] screen in
            guard let self else { return (nil, nil) }
            return (topBar.enabled ? topBar.frame(on: screen) : nil, dock.enabled ? DockGeometry.frame(visible: screen.visibleFrame, count: dock.model.items.count + 1) : nil)
        }
        startWindowManager()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            var id = EventHotKeyID()
            guard let pointer, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4d4e4f4d, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<Delegate>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in delegate.showActivities() }; return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(ShortcutChoice.choice(forMask: UserDefaults.standard.integer(forKey: "shortcutModifiers")).mask), EventHotKeyID(signature: 0x4d4e4f4d, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.isActive, let window = NSApp.keyWindow, !KeyboardSink.isSink(window) else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.control), !modifiers.contains(.command), !modifiers.contains(.option) {
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                switch key {
                case "f": if !self.overview.isOpen { self.overview.open(apps: false) }; return nil
                case "w": if window is OverviewPanel { self.overview.close() } else if window.styleMask.contains(.closable) { window.performClose(nil) } else { window.orderOut(nil) }; return nil
                case "q": self.quit(); return nil
                case ",": self.showPreferences(); return nil
                case "?", "/": self.showKeyboardShortcuts(); return nil
                default: break
                }
                if let editor = window.firstResponder as? NSTextView {
                    switch key { case "a": editor.selectAll(nil); case "c":editor.copy(nil); case "x":editor.cut(nil); case "v":editor.paste(nil); case "z": if modifiers.contains(.shift) { editor.undoManager?.redo() } else { editor.undoManager?.undo() }; default:return event }; return nil
                }
            }
            // AppKit/SwiftUI route Return, arrows, Tab and Escape to the focused control/container.
            return event
        }
        // A display that comes, goes or changes size: not the Dock appearing, which only changes the visible area.
        var frames = NSScreen.screens.map(\.frame)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in let now = NSScreen.screens.map(\.frame); if now != frames { frames = now; self?.overview.close() } }
        }
    }
    @objc func showPreferences() { ShellUtilities.shared.showPreferences() }
    @objc func showKeyboardShortcuts() { ShellUtilities.shared.showShortcuts() }
    @objc func showAbout() { ShellUtilities.shared.showAbout() }
    @objc func focusDock() { dock.focus() }
    @objc func focusTopBar() { topBar.focus() }
    @objc func changeShortcut(_ sender: NSMenuItem) { applyShortcut(ShortcutChoice.choice(forMask: sender.tag)) }
    func applyShortcut(_ choice: ShortcutChoice) {
        let previous = ShortcutChoice.choice(forMask: UserDefaults.standard.integer(forKey: "shortcutModifiers"))
        if let hotkey { UnregisterEventHotKey(hotkey) }
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(choice.mask), EventHotKeyID(signature: 0x4d4e4f4d, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        if result == noErr { UserDefaults.standard.set(choice.mask, forKey: "shortcutModifiers"); UserDefaults.standard.set(choice.title, forKey: "shortcutTitle"); model.shortcutTitle = choice.title }
        else { RegisterEventHotKey(UInt32(kVK_Space), UInt32(previous.mask), EventHotKeyID(signature: 0x4d4e4f4d, id: 1), GetApplicationEventTarget(), 0, &hotkey); let alert = NSAlert(); alert.messageText = "Shortcut unavailable"; alert.informativeText = "Choose another shortcut from Quick Settings."; alert.runModal() }
    }
    func applicationWillTerminate(_ notification: Notification) { windowManager.shutDown(); topBar.stop(); dock.stop(); OverviewController.restoreDockAfterCrash(); macChrome.restoreAll(quitting: true) }
    /// `kill`, Ctrl+C and a closing terminal quit the ordinary way, so windows and the Mac's settings come back.
    private var signals: [DispatchSourceSignal] = []
    func quitOnSignals() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }; source.resume(); signals.append(source)
        }
    }
    /// Window control needs Accessibility. Asked for once; after that it starts as soon as it is granted.
    func startWindowManager() {
        if AXIsProcessTrusted() { windowManager.start(); dragTiler = dragTiler ?? DragTiler(windowManager); startHotCorner(); startGestures(); startShortcuts(); return }
        if !UserDefaults.standard.bool(forKey: "askedForAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedForAccessibility")
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startWindowManager() }
    }
    private func startGestures() { gestures.popup = { [weak self] in self?.showWorkspacePopup() }; gestures.start(); slide.warmUp() }
    /// Not over a full-screen window: there it would open while reaching for the app's own menu.
    private func startHotCorner() {
        hotCorner.triggered = { [weak self] in
            guard let self else { return }
            let fullScreen = windowManager.state.flatMap { s in s.focus.flatMap(s.window)?.fullscreen } ?? false
            guard !fullScreen || overview.isOpen else { return }
            overview.toggle(apps: false)
        }
        hotCorner.start()
    }
    private func updateDesktop() { desktop.set(shown: macChrome.hidden.contains(.desktop)) }
    func startShortcuts() {
        let store = ShortcutStore.shared
        store.superTapped = { [weak self] in self?.overview.toggle(apps: false) }
        store.run = { [weak self] in self?.perform($0) }
        switcher.windowManager = windowManager; switcher.endKeys = { store.endSwitcher() }
        store.switcher = { [weak self] in self?.switcher.handle($0) }
        store.media = { [weak self] in self?.mediaKey($0) }
        store.start()
        mediaWatch = topBar.status.$volume.sink { [weak self] _ in DispatchQueue.main.async { self?.takeMediaKeys() } }
        screensWatch = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.takeMediaKeys() } }
    }
    /// Only what Mnome can do itself: an output with its own volume, the built-in display's brightness.
    private func takeMediaKeys() { ShortcutStore.shared.takeMedia(volume: topBar.status.volumeSettable, brightness: topBar.controls.builtIn.flatMap(Private.brightness) != nil) }
    private func mediaKey(_ key: MediaKey) {
        let status = topBar.status, controls = topBar.controls
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard let volume = status.volume else { return }
            if key == .mute { status.setMuted(!volume.muted) } else { status.setVolume(MediaKey.step(volume.level, up: key == .volumeUp)) }
            guard let now = status.volume else { return }
            osd.show(icon: StatusIcons.volume(level: now.level, muted: now.muted), fallback: "speaker.wave.2", level: now.muted ? 0 : now.level)
        case .brightnessUp, .brightnessDown:
            guard let id = controls.builtIn, let level = Private.brightness(id) else { return }
            controls.setBrightness(MediaKey.step(Double(level), up: key == .brightnessUp))
            osd.show(icon: "display-brightness-symbolic", fallback: "sun.max", level: Private.brightness(id).map(Double.init))
        }
    }
    func perform(_ action: ShellAction) {
        if let index = action.launchIndex { if dock.model.items.indices.contains(index) { dock.model.open(dock.model.items[index]) }; return }
        switch action {
        case .appGrid: overview.toggle(apps: true)
        case .quickSettings: topBar.toggleQuickSettings()
        case .dateMenu: topBar.toggleDateMenu()
        case .runCommand: topBar.toggleRunDialog()
        case .lock: if !Private.lockScreen() { NSLog("Mnome: this macOS cannot lock the screen this way") }
        case .tileLeft: windowManager.withFocused { .snap($0, .left) }
        case .tileRight: windowManager.withFocused { .snap($0, .right) }
        case .maximize: windowManager.withFocused { .snap($0, .maximize) }
        case .restore: windowManager.withFocused { .restore($0) }
        case .minimize: windowManager.withFocused { .minimize($0) }
        case .center: windowManager.withFocused { .center($0) }
        case .close: windowManager.closeFocused()
        case .showDesktop: if windowManager.running { windowManager.send(.showDesktop) }
        case .cycle: if windowManager.running { windowManager.send(.cycle(backwards: false)) }
        case .cycleBack: if windowManager.running { windowManager.send(.cycle(backwards: true)) }
        case .moveLeft: windowManager.withFocused { .toDisplay($0, .left) }
        case .moveRight: windowManager.withFocused { .toDisplay($0, .right) }
        case .moveUp: windowManager.withFocused { .toDisplay($0, .up) }
        case .moveDown: windowManager.withFocused { .toDisplay($0, .down) }
        case .workspacePrevious: switchWorkspace { _ in .stepWorkspace(-1) }
        case .workspaceNext: switchWorkspace { _ in .stepWorkspace(1) }
        case .workspaceFirst: switchWorkspace { $0.workspaces.first.map(WMEvent.setWorkspace) }
        case .workspaceLast: switchWorkspace { $0.workspaces.last.map(WMEvent.setWorkspace) }
        case .carryPrevious, .carryNext:
            let delta = action == .carryNext ? 1 : -1
            Task { if let id = await windowManager.registry.focusedWindow(), windowManager.state?.isShown(id) == true { switchWorkspace { _ in .carryWindow(id, delta) } } }
        default: break
        }
    }
    private func switchWorkspace(_ make: (WMState) -> WMEvent?) {
        guard windowManager.running, let state = windowManager.state, state.workspacesOn, let event = make(state) else { return }
        guard !overview.isOpen else { windowManager.send(event); return } // the overview slides itself
        Task { await slide.perform(event, sent: showWorkspacePopup) }
    }
    private func showWorkspacePopup() {
        if !overview.isOpen, let now = windowManager.state, let i = now.workspaces.firstIndex(of: now.current) { workspacePopup.show(count: now.workspaces.count, current: i) }
    }
    @objc func bringBackWindows() {
        Task {
            let failed = AXIsProcessTrusted() ? await windowManager.bringBackAll() : -1
            guard failed != 0 else { return }
            let alert = NSAlert(); alert.messageText = failed < 0 ? "Mnome needs Accessibility" : "Some windows could not be brought back"
            alert.informativeText = failed < 0 ? "Allow Mnome in System Settings → Privacy & Security → Accessibility, then try again." : "\(failed) did not answer. Try again when their apps respond."
            alert.runModal()
        }
    }
    @objc func restoreMacChrome() { macChrome.restoreAll() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { item.action == #selector(restoreMacChrome) ? macChrome.needsRestore : true }
    @objc func toggleDock(_ sender: NSMenuItem) { setDockVisible(!dock.enabled) }
    func setDockVisible(_ visible: Bool) {
        dock.setVisible(visible); windowManager.updateDisplays()
        status.menu?.items.first(where: { $0.action == #selector(toggleDock(_:)) })?.state = dock.enabled ? .on : .off
    }
    func updateFavoritesMenu() {
        guard let menu = status.menu?.items.first(where: { $0.title == "Favorites" })?.submenu else { return }
        menu.removeAllItems()
        for favorite in dock.model.favorites {
            let missing = dock.model.resolved(favorite) == nil ? " (unavailable)" : ""
            let item = NSMenuItem(title: "Remove \(favorite.name)\(missing)", action: #selector(removeFavorite(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = favorite.id; menu.addItem(item)
        }
        if menu.items.isEmpty { let item = NSMenuItem(title: "No favorites", action: nil, keyEquivalent: ""); menu.addItem(item) }
    }
    @objc func removeFavorite(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { dock.model.remove(id) } }
    @objc func toggleTopBar(_ sender: NSMenuItem) { setTopBarVisible(!topBar.enabled) }
    /// Mnome's own top bar, or the Mac's menu bar with Mnome's items in place of the Mac's status icons.
    func setTopBarVisible(_ visible: Bool) {
        topBar.setVisible(visible)
        macChrome.set(.menuBar, hidden: visible); macChrome.set(.statusIcons, hidden: true) // Mnome draws status itself in either bar, and the apps' icons in its own
        statusItems.set(shown: !visible); statusItems.dateOnly = !visible; status.isVisible = visible
        if visible { appMenus.start(); appIcons.start() } else { appMenus.stop(); appIcons.stop() }
        windowManager.updateDisplays()
        status.menu?.items.first(where: { $0.action == #selector(toggleTopBar(_:)) })?.state = topBar.enabled ? .on : .off
    }
    func showActivities() { overview.toggle(apps: false) }
    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
    @objc func openNetworkSettings() { openSettings("com.apple.Network-Settings.extension") }
    @objc func openBatterySettings() { openSettings("com.apple.Battery-Settings.extension") }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggle() { overview.toggle(apps: false) }
}
MainActor.assumeIsolated {
 if CommandLine.arguments.contains("--self-test") {
    let result = core(["version": 1, "op": "search", "query": "term", "apps": [["id": "terminal", "name": "Terminal"], ["id": "safari", "name": "Safari"]]])
    guard let apps = result["apps"] as? [[String: Any]], apps.count == 1, apps[0]["id"] as? String == "terminal" else { fatalError("Bridge search failed") }
    let malformed = core(["op": "unsupported"])
    guard malformed["ok"] as? Bool == false else { fatalError("Bridge malformed request failed") }
    let dockResult = core(["version": 1, "op": "dock", "favorites": [["id": "terminal", "name": "Terminal"]], "running": [["id": "terminal", "name": "Terminal"]]])
    guard let dockItems = dockResult["items"] as? [[String: Any]], dockItems.count == 1, dockItems[0]["pinned"] as? Bool == true, dockItems[0]["running"] as? Bool == true else { fatalError("Dock bridge failed") }
    let layoutResult = core(["version":1,"op":"layout","windows":[["id":"a","width":100,"height":600],["id":"b","width":600,"height":100]],"width":320,"height":120,"min_card_width":160,"min_card_height":128,"caption_height":32])
    guard let cards = layoutResult["cards"] as? [[String:Any]], cards.count == 2, let contentHeight = layoutResult["content_height"] as? Double, contentHeight >= 128 else { fatalError("Adaptive layout bridge failed") }
    let navigation = core(["version":1,"op":"navigate","cards":[["id":"a","x":0,"y":0,"width":100,"height":100],["id":"b","x":120,"y":0,"width":100,"height":100]],"selected":"a","direction":"right"])
    guard navigation["selected"] as? String == "b" else { fatalError("Navigation bridge failed") }
    if case .success = coreResult(["op":"unsupported"]) { fatalError("Bridge must expose errors") }
    let prefs = CFPreferencesStore(); let domain = "dev.mnome.selftest"
    prefs.set(domain, "b", .bool(true)); prefs.set(domain, "i", .int(7)); prefs.set(domain, "d", .double(1000)); prefs.set(domain, "s", .string("x"))
    guard prefs.get(domain, "b") == .bool(true), prefs.get(domain, "i") == .int(7), prefs.get(domain, "d") == .double(1000), prefs.get(domain, "s") == .string("x") else { fatalError("Preference store round trip failed") }
    for key in ["b", "i", "d", "s"] { prefs.set(domain, key, .absent) }
    guard prefs.get(domain, "b") == .absent else { fatalError("Preference store must delete absent keys") }
    MainActor.assumeIsolated {
        Adwaita.registerFont(); guard Adwaita.fontReady else { fatalError("Adwaita Sans did not register") }
        for name in ["network-wired-symbolic", "audio-volume-muted-symbolic", "battery-level-100-charged-symbolic", "system-shutdown-symbolic", StatusIcons.network(available: true, wifi: true, rssi: -70), StatusIcons.battery(percent: 37, charging: true)] {
            guard let icon = Adwaita.icon(name), icon.size.width > 0 else { fatalError("Missing Adwaita icon \(name)") }
        }
    }
    nonisolated(unsafe) var outcomes: [String?]?
    Task.detached { outcomes = [await Runner.shell("true"), await Runner.shell("mnome-no-such-command-x")] }
    let deadline = Date().addingTimeInterval(20)
    while outcomes == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } // the process's exit arrives through the main loop
    guard let outcomes, outcomes.count == 2, outcomes[0] == nil, outcomes[1]?.hasPrefix("No such command") == true else { fatalError("Run a Command: \(outcomes)") }
    guard Runner.application(named: "terminal")?.lastPathComponent == "Terminal.app", Runner.application(named: "ls -la") == nil else { fatalError("Run a Command does not find applications") }
    print("Mnome bridge self-test passed"); exit(0)
 }
 if let flag = CommandLine.arguments.firstIndex(of: "--make-app-grid-icon"), CommandLine.arguments.indices.contains(flag + 1) { AppGridIcon.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])); exit(0) }
 if CommandLine.arguments.contains("--permissions") {
    // Start it through `open`, so macOS checks Mnome itself rather than the terminal that launched it.
    print("Mnome permissions: accessibility \(AXIsProcessTrusted()) screen-recording \(CGPreflightScreenCaptureAccess())"); exit(0)
 }
 if CommandLine.arguments.contains("--rescue") {
    if NSRunningApplication.runningApplications(withBundleIdentifier: "dev.mnome.shell").allSatisfy({ $0.processIdentifier == getpid() }) { OverviewController.restoreDockAfterCrash(); MacChromeController().restoreAll(quitting: true) } // a crash leaves the menu bar and Dock hidden; that needs no Accessibility
    guard AXIsProcessTrusted() else { print("Mac settings are back. Mnome needs Accessibility to move windows."); exit(1) }
    let given = CommandLine.arguments.firstIndex(of: "--rescue").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil } // a check's own file: only its windows
    let journal = RecoveryJournal(url: given ?? WindowManager.defaultJournal)
    guard journal.acquire() else { print("Mnome is running: use Bring Back All Windows in its menu."); exit(1) }
    Task { let failed = await RecoveryRunner.restore(journal) + (given == nil ? RecoveryRunner.centerStrays() : 0); print(failed == 0 ? "All windows are on screen." : "\(failed) windows could not be brought back."); exit(failed == 0 ? 0 : 1) }
    RunLoop.main.run()
 }
 if CommandLine.arguments.contains("--engine-windows") { EngineWindows.run() }
 if CommandLine.arguments.contains("--quit") { // the ordinary way, so it puts everything back
    let mine = { NSRunningApplication.runningApplications(withBundleIdentifier: "dev.mnome.shell").filter { $0.processIdentifier != getpid() } }
    mine().forEach { _ = $0.terminate() }
    for _ in 0..<100 { if mine().isEmpty { exit(0) }; RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    print("Mnome did not quit."); exit(1)
 }
 if CommandLine.arguments.contains("--key-window") { KeyWindow.run() }
 if CommandLine.arguments.contains("--system-check") { SystemCheck.run() }
 if CommandLine.arguments.contains("--engine-check") { EngineCheck.run() }
 if CommandLine.arguments.contains("--key-check") { KeyCheck.run() }
 if CommandLine.arguments.contains("--overview-check") { OverviewCheck.run() }
 let app = NSApplication.shared
 if let flag = CommandLine.arguments.firstIndex(of: "--gallery") {
    guard CommandLine.arguments.indices.contains(flag + 1) else { fatalError("Usage: Mnome --gallery DIR") }
    do { try Gallery.render(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])); exit(0) } catch { fatalError("Gallery failed: \(error)") }
 }
 let delegate = Delegate()
 app.delegate = delegate
 app.run()
}
