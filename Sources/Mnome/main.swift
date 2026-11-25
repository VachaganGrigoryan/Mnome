import AppKit
import SwiftUI
import ScreenCaptureKit
import Carbon
import Combine
import CMnome
import MnomeSupport

struct AppItem: Identifiable { let id: String; let name: String; let url: URL }
struct WindowItem: Identifiable { let id: UInt32; let pid: pid_t; let title: String; let frame: CGRect; var image: NSImage? }
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
    @Published var query = ""; @Published var apps: [AppItem] = []; @Published var windows: [WindowItem] = []
    @Published var overview = false; @Published var message = ""; @Published var selection = 0
    var close: ((_ reactivate: Bool) -> Void)?
    var focusWindow: ((UInt32) -> Bool)?
    @Published var filtered: [AppItem] = []
    @Published var appState: PresentationState = .loading
    @Published var windowState: PresentationState = .empty
    @Published var selectedWindow: UInt32?
    @Published var searchFocusRequest = UUID()
    @Published var shortcutTitle = "Control–Option–Space"
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
            Task { @MainActor in self.apps = items; self.search() }
        }
    }
    func launch(_ item: AppItem) { NSWorkspace.shared.openApplication(at: item.url, configuration: .init()) { app, error in Task { @MainActor in if let error { self.appState = .error(error.localizedDescription) } else { self.close?(false); _ = app?.activate() } } } }
    var generation = UUID()
    func fallbackWindows() {
            let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            windows = entries.compactMap { entry in
                guard let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ProcessInfo.processInfo.processIdentifier,
                let id = entry[kCGWindowNumber as String] as? UInt32, entry[kCGWindowLayer as String] as? Int == 0,
                let bounds = entry[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 40, rect.height > 40 else { return nil }
                return WindowItem(id: id, pid: pid, title: entry[kCGWindowName as String] as? String ?? entry[kCGWindowOwnerName as String] as? String ?? "Window", frame: rect, image: nil)
            }
    }
    func refreshWindows() {
        generation = UUID(); let current = generation
        windows = []; message = ""; windowState = .loading
        guard CGPreflightScreenCaptureAccess() else {
            message = "Enable Screen Recording for thumbnails. Window titles may be unavailable until permission is granted."
            fallbackWindows(); windowState = windows.isEmpty ? .empty : .content
            return
        }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let eligible = content.windows.filter { $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
                for window in eligible {
                    guard current == generation else { return }
                    guard let owner = window.owningApplication else { continue }
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = SCStreamConfiguration(); let scale = 480 / max(window.frame.width, window.frame.height); config.width = max(1, Int(window.frame.width * scale)); config.height = max(1, Int(window.frame.height * scale)); config.showsCursor = false
                    let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard current == generation else { return }
                    windows.append(WindowItem(id: window.windowID, pid: owner.processID, title: window.title?.isEmpty == false ? window.title! : owner.applicationName, frame: window.frame, image: image.map { NSImage(cgImage: $0, size: .zero) }))
                }
                windowState = windows.isEmpty ? .empty : .content; if let selectedWindow, !windows.contains(where: { $0.id == selectedWindow }) { self.selectedWindow = nil }
            } catch { guard current == generation else { return }; fallbackWindows(); windowState = windows.isEmpty ? .error("Window capture failed. Try refreshing.") : .content; message = "Window previews unavailable. Showing available window titles and icons." }
        }
    }
    func focus(_ item: WindowItem) {
        close?(false) // reactivating the previous app here would race the window being raised
        if focusWindow?(item.id) == true { return } // known exactly; what follows guesses by title and frame
        DispatchQueue.global(qos: .userInitiated).async {
            guard let app = NSRunningApplication(processIdentifier: item.pid) else { return }
            let ax = AXUIElementCreateApplication(item.pid)
            var raw: CFTypeRef?
            var matched: [AXUIElement] = []
            if AXIsProcessTrusted(), AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &raw) == .success, let list = raw as? [AXUIElement] {
                for window in list {
                    var title: CFTypeRef?; var position: CFTypeRef?; var size: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                    AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position)
                    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size)
                    var point = CGPoint.zero; var dimensions = CGSize.zero
                    if let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                        AXValueGetValue(position as! AXValue, .cgPoint, &point); AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
                        if abs(point.x-item.frame.minX) < 3 && abs(point.y-item.frame.minY) < 3 && abs(dimensions.width-item.frame.width) < 3 && abs(dimensions.height-item.frame.height) < 3 && (title as? String ?? "") == item.title { matched.append(window) }
                    }
                }
            }
            DispatchQueue.main.sync { _ = app.activate() }
            if matched.count == 1 { AXUIElementPerformAction(matched[0], kAXRaiseAction as CFString) }
        }
    }
}
struct ShellView: View {
    var displayFrame: CGRect
    @ObservedObject var model: Model
    @ObservedObject var dock: DockModel
    @FocusState private var searchFocused: Bool
    private var content: OverviewContent { OverviewContent.content(query: model.query, windowsMode: model.overview) }
    private var matchingWindows: [WindowItem] {
        model.windows.filter { OverviewContent.matches(query: model.query, title: $0.title, app: NSRunningApplication(processIdentifier: $0.pid)?.localizedName ?? "") }
    }
    private var appsFailed: Bool { if case .error = model.appState { return true }; return false }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Color.clear.frame(width: 36, height: 36)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ShellPalette.dim).accessibilityHidden(true)
                    TextField("Type to search", text: $model.query).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Search Applications and Windows")
                        .onSubmit { if let item = model.filtered.first { model.launch(item) } else if let window = matchingWindows.first { model.focus(window) } }
                }.padding(.horizontal, 16).frame(height: 40).background(Color.white.opacity(0.1)).clipShape(Capsule()).frame(maxWidth: 480)
                Spacer()
                Button { model.close?(true) } label: { Image(systemName: "xmark").frame(width: 36, height: 36).background(ShellPalette.toggle).clipShape(Circle()) }
                    .buttonStyle(ShellButtonStyle()).help("Close (Ctrl+W)").accessibilityLabel("Close")
            }
            switch content {
            case .windows:
                if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary) }
                if model.windowState == .loading { ProgressView("Loading Windows") }
                else if model.windows.isEmpty { placeholder(model.windowState, empty: "No Windows", detail: "Open an application window on this desktop.") }
                WindowOverview(model: model, displayFrame: displayFrame)
                HStack {
                    if !CGPreflightScreenCaptureAccess() { Button("Enable Window Previews") { CGRequestScreenCaptureAccess(); model.refreshWindows() }.buttonStyle(AdwaitaButtonStyle(.pill)) }
                    if !AXIsProcessTrusted() { Button("Enable Window Control") { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }.buttonStyle(AdwaitaButtonStyle(.pill)) }
                    Button("Refresh") { model.refreshWindows() }.buttonStyle(AdwaitaButtonStyle(.pill))
                }
            case .appGrid, .searchResults:
                let windows = content == .searchResults ? matchingWindows : []
                if model.appState == .loading && windows.isEmpty { ProgressView("Finding Applications") }
                else if (model.filtered.isEmpty || appsFailed) && windows.isEmpty { placeholder(model.appState, empty: content == .searchResults ? "No Results" : "No Applications Found", detail: "Try a different search.") }
                ScrollView { VStack(alignment: .leading, spacing: 16) {
                    if !windows.isEmpty {
                        Text("Windows").font(.headline).padding(.leading, 4)
                        BoxedList { ForEach(windows) { window in
                            ActionRow(title: window.title, subtitle: NSRunningApplication(processIdentifier: window.pid)?.localizedName, icon: "macwindow", action: { model.focus(window) })
                        } }
                        if !model.filtered.isEmpty { Text("Applications").font(.headline).padding(.leading, 4) }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 16) { ForEach(model.filtered) { item in
                        Button { model.launch(item) } label: { VStack(spacing: 8) { Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 96, height: 96); Text(item.name).font(.body).lineLimit(2).multilineTextAlignment(.center).frame(minHeight: 36) }.padding(12).frame(maxWidth: .infinity) }.buttonStyle(ShellButtonStyle(radius: 18)).help(item.name).accessibilityLabel(item.name).contextMenu { Button(dock.isPinned(item.url) ? "Unpin from Dash" : "Pin to Dash") { dock.togglePin(item.url, name: item.name) } }
                    }
                } }.frame(maxWidth: .infinity) }
            }
            Text("\(model.shortcutTitle) · Esc to close").foregroundStyle(ShellPalette.dim).font(.caption)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(ShellPalette.overview).clipShape(RoundedRectangle(cornerRadius: 24)).shellTheme()
        .onExitCommand { switch EscapeAction.escape(query: model.query) { case .clearSearch: model.query = ""; case .close: model.close?(true) } }
        .onAppear { searchFocused = true }
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: model.overview) { _, _ in searchFocused = true; model.refreshWindows() }
        .onChange(of: model.query) { _, _ in model.search() }
    }
    @ViewBuilder func placeholder(_ state: PresentationState, empty: String, detail: String) -> some View {
        if case let .error(error) = state { StatusPage(icon: "exclamationmark.triangle", title: "Something Went Wrong", detail: error, actionTitle: "Try Again") { model.refreshWindows(); model.discover() } }
        else { StatusPage(icon: content == .windows ? "macwindow" : "magnifyingglass", title: empty, detail: detail) }
    }
}
struct OverviewCard: Identifiable { let id: String; let rect: CGRect; let previewHeight: CGFloat }
struct WindowOverview: View {
    @ObservedObject var model: Model
    var displayFrame: CGRect
    var displayWindows: [WindowItem] { model.windows.filter { displayFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) } }
    var revision: String { displayWindows.map { "\($0.id):\($0.frame)" }.joined(separator: ";") }
    @State private var cards: [OverviewCard] = []; @State private var contentHeight: CGFloat = 0; @State private var generation = UUID(); @State private var layoutError: String?
    @FocusState private var focused: String?
    func layout(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        generation = UUID(); let current = generation
        let windows = displayWindows.map { ["id": String($0.id), "width": $0.frame.width, "height": $0.frame.height] as [String: Any] }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = core(["version": 1, "op": "layout", "windows": windows, "width": size.width, "height": size.height, "min_card_width": 160, "min_card_height": 128, "caption_height": 32])
            let output = (result["cards"] as? [[String: Any]] ?? []).compactMap { card -> OverviewCard? in
                guard let id = card["id"] as? String, let x = card["x"] as? Double, let y = card["y"] as? Double, let width = card["width"] as? Double, let height = card["height"] as? Double else { return nil }
                return OverviewCard(id: id, rect: CGRect(x:x,y:y,width:width,height:height), previewHeight: max(16,height-64))
            }
            DispatchQueue.main.async { if generation == current { cards = output; layoutError = result["ok"] as? Bool == false ? "Window layout failed. Refresh to try again." : nil; contentHeight = result["content_height"] as? Double ?? size.height } }
        }
    }
    func navigate(_ direction: String) {
        let response = core(["version":1,"op":"navigate","cards":cards.map { ["id":$0.id,"x":$0.rect.minX,"y":$0.rect.minY,"width":$0.rect.width,"height":$0.rect.height] as [String:Any] },"selected":focused ?? cards.first?.id ?? "","direction":direction])
        if let id = response["selected"] as? String { focused = id; model.selectedWindow = UInt32(id) }
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in ScrollView {
                ZStack(alignment: .topLeading) { ForEach(cards) { card in
                    if let window = model.windows.first(where: { String($0.id) == card.id }) {
                        Button { model.selectedWindow = window.id; model.focus(window) } label: {
                            VStack(spacing: 8) { if let image = window.image { Image(nsImage:image).resizable().scaledToFit().frame(height:card.previewHeight) } else { Image(nsImage:NSRunningApplication(processIdentifier:window.pid)?.icon ?? NSImage()).resizable().scaledToFit().frame(height:card.previewHeight) }; Text(window.title).font(.caption).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 2).background(Color.black.opacity(0.4)).clipShape(Capsule()) }.padding(8).frame(width:card.rect.width,height:card.rect.height)
                        }.buttonStyle(.plain).background(ThemePalette.surface).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius:12).stroke(focused == card.id ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: focused == card.id ? 3 : 1)).focused($focused, equals:card.id).help(window.title).accessibilityLabel(window.title).id(card.id).offset(x:card.rect.minX,y:card.rect.minY)
                    }
                } }.frame(width:geometry.size.width,height:max(geometry.size.height,contentHeight),alignment:.topLeading)
            }.onChange(of: focused) { _, id in if let id { model.selectedWindow = UInt32(id); proxy.scrollTo(id) } } }
            .onMoveCommand { direction in switch direction { case .left:navigate("left"); case .right:navigate("right"); case .up:navigate("up"); case .down:navigate("down"); default:break } }
            .overlay { if let layoutError { StatusPage(icon: "exclamationmark.triangle", title: "Something Went Wrong", detail: layoutError, actionTitle: "Try Again") { layout(geometry.size) }.background(ShellPalette.overview) } }
            .onAppear { layout(geometry.size) }.onChange(of:revision) { _,_ in layout(geometry.size) }.onChange(of:geometry.size) { _,size in layout(size) }
        }
    }
}
final class ShellPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let topBar = TopBarController()
    let dock = DockController()
    let macChrome = MacChromeController()
    let windowManager = WindowManager()
    let switcher = SwitcherController(), workspacePopup = WorkspacePopup()
    private var workspaceWatch: AnyCancellable?
    let model = Model(); var panel: NSPanel?; var panels: [NSPanel] = []; var status: NSStatusItem!; var hotkey: EventHotKeyRef?; var previous: NSRunningApplication?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory); model.shortcutTitle = UserDefaults.standard.string(forKey: "shortcutTitle") ?? "Control–Option–Space"; model.discover(); model.close = { [weak self] in self?.dismiss(reactivate: $0) }
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
        dock.model.beforeOpen = { [weak self] in if self?.panel?.isVisible == true { self?.dismiss(reactivate: false) } }
        dock.changed = { [weak self] in self?.updateFavoritesMenu() }
        dock.model.showApps = { [weak self] in guard let self else { return }; if self.panel?.isVisible == true { self.dismiss() } else { self.model.overview = false; self.toggle() } }
        dock.start()
        updateFavoritesMenu()
        topBar.activities = { [weak self] in self?.showActivities() }
        topBar.model = model; topBar.dock = dock.model; topBar.macChrome = macChrome
        macChrome.changed = { [weak self] in self?.topBar.rebuild(); self?.dock.rebuild(); self?.windowManager.updateDisplays() }
        topBar.actions = QuickActions(
            openMnome: { [weak self] in self?.showActivities() }, preferences: { [weak self] in self?.showPreferences() }, shortcuts: { [weak self] in self?.showKeyboardShortcuts() },
            about: { [weak self] in self?.showAbout() }, quit: { [weak self] in self?.quit() }, systemSettings: { [weak self] in self?.openSettings("") },
            networkSettings: { [weak self] in self?.openNetworkSettings() }, batterySettings: { [weak self] in self?.openBatterySettings() },
            focusDock: { [weak self] in self?.focusDock() }, focusTopBar: { [weak self] in self?.focusTopBar() }, setWorkspaces: { [weak self] in self?.windowManager.workspacesWanted = $0 },
            toggleTopBar: { [weak self] in self?.setTopBarVisible(!(self?.topBar.enabled ?? true)) }, toggleDock: { [weak self] in self?.setDockVisible(!(self?.dock.enabled ?? true)) },
            setShortcut: { [weak self] in self?.applyShortcut($0) }, removeFavorite: { [weak self] in self?.dock.model.remove($0) },
            toggleMacChrome: { [weak self] in guard let self else { return }; self.macChrome.setAll(hidden: self.macChrome.hidden.isEmpty) }, bringBackWindows: { [weak self] in self?.bringBackWindows() })
        ShellUtilities.shared.configure(actions: topBar.actions, model: model, dock: dock.model, macChrome: macChrome)
        Adwaita.registerFont(); macChrome.hideChosen(); topBar.start()
        workspaceWatch = windowManager.$state.sink { [weak self] state in
            guard let self, let state else { return }
            let now = BarWorkspaces(count: state.workspaces.count, current: state.workspaces.firstIndex(of: state.current) ?? 0, on: state.workspacesOn)
            if self.topBar.status.workspaces != now { self.topBar.status.workspaces = now }
        }
        windowManager.reserved = { [weak self] screen in
            guard let self else { return (nil, nil) }
            return (topBar.enabled ? topBar.frame(on: screen) : nil, dock.enabled ? DockGeometry.frame(visible: screen.visibleFrame, count: dock.model.items.count + 1) : nil)
        }
        model.focusWindow = { [weak self] in self?.windowManager.focus(UInt64($0)) ?? false }
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
                case "f": if self.panel?.isVisible != true { self.model.overview = false; self.toggle() }; self.model.searchFocusRequest = UUID(); return nil
                case "r": guard self.panels.contains(where: { $0 === window }) else { return event }; self.model.refreshWindows(); self.model.discover(); return nil
                case "w": if self.panels.contains(where: { $0 === window }) { self.dismiss() } else if window.styleMask.contains(.closable) { window.performClose(nil) } else { window.orderOut(nil) }; return nil
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
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.panel?.isVisible == true { self?.dismiss() } }
        }
        model.overview = true; toggle()
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
    func applicationWillTerminate(_ notification: Notification) { windowManager.shutDown(); topBar.stop(); dock.stop(); macChrome.restoreAll(quitting: true) }
    /// Window control needs Accessibility. Asked for once; after that it starts as soon as it is granted.
    func startWindowManager() {
        if AXIsProcessTrusted() { windowManager.start(); startShortcuts(); return }
        if !UserDefaults.standard.bool(forKey: "askedForAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedForAccessibility")
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startWindowManager() }
    }
    func startShortcuts() {
        let store = ShortcutStore.shared
        store.superTapped = { [weak self] in guard let self else { return }; if panel?.isVisible == true { dismiss() } else { showActivities() } }
        store.run = { [weak self] in self?.perform($0) }
        switcher.windowManager = windowManager; switcher.endKeys = { store.endSwitcher() }
        store.switcher = { [weak self] in self?.switcher.handle($0) }
        store.start()
    }
    func perform(_ action: ShellAction) {
        if let index = action.launchIndex { if dock.model.items.indices.contains(index) { dock.model.open(dock.model.items[index]) }; return }
        switch action {
        case .appGrid: if panel?.isVisible == true && !model.overview { dismiss() } else if panel?.isVisible == true { model.overview = false } else { model.overview = false; toggle() }
        case .quickSettings: topBar.toggleQuickSettings()
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
        windowManager.send(event)
        if let now = windowManager.state, let i = now.workspaces.firstIndex(of: now.current) { workspacePopup.show(count: now.workspaces.count, current: i) }
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
    func setTopBarVisible(_ visible: Bool) {
        topBar.setVisible(visible); windowManager.updateDisplays()
        status.menu?.items.first(where: { $0.action == #selector(toggleTopBar(_:)) })?.state = topBar.enabled ? .on : .off
    }
    func showActivities() {
        if panel?.isVisible == true && model.overview { dismiss(); return }
        if panel?.isVisible == true { model.overview = true; model.refreshWindows(); return }
        model.overview = true; toggle()
    }
    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
    @objc func openNetworkSettings() { openSettings("com.apple.Network-Settings.extension") }
    @objc func openBatterySettings() { openSettings("com.apple.Battery-Settings.extension") }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggle() {
        if panel?.isVisible == true { dismiss(); return }
        previous = NSWorkspace.shared.frontmostApplication
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        for display in NSScreen.screens {
        let frame = display.visibleFrame.insetBy(dx: 35, dy: 35)
        let window = ShellPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.isFloatingPanel = true; window.level = .floating; window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: ShellView(displayFrame: CGRect(x: display.frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - display.frame.maxY, width: display.frame.width, height: display.frame.height), model: model, dock: dock.model)); window.isReleasedWhenClosed = false
        panels.append(window); window.orderFrontRegardless(); if display == screen { panel = window }
        }
        model.refreshWindows(); NSApp.activate(); panel?.makeKeyAndOrderFront(nil)
    }
    func dismiss(reactivate: Bool = true) { model.generation = UUID(); model.query = ""; panels.forEach { $0.orderOut(nil) }; panels = []; panel = nil
        guard reactivate else { return }
        // To what the window manager wants in front: the app from before may only have windows on another workspace now.
        if windowManager.running { if let id = windowManager.state?.focus, windowManager.focus(id) { return }; Task { _ = await windowManager.sink.take() }; return }
        previous?.activate()
    }
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
    print("Mnome bridge self-test passed"); exit(0)
 }
 if CommandLine.arguments.contains("--permissions") {
    // Start it through `open`, so macOS checks Mnome itself rather than the terminal that launched it.
    print("Mnome permissions: accessibility \(AXIsProcessTrusted()) screen-recording \(CGPreflightScreenCaptureAccess())"); exit(0)
 }
 if CommandLine.arguments.contains("--rescue") {
    guard AXIsProcessTrusted() else { print("Mnome needs Accessibility to move windows."); exit(1) }
    if NSRunningApplication.runningApplications(withBundleIdentifier: "dev.mnome.shell").allSatisfy({ $0.processIdentifier == getpid() }) { MacChromeController().restoreAll(quitting: true) } // a crash leaves the menu bar and Dock hidden
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
 let app = NSApplication.shared
 if let flag = CommandLine.arguments.firstIndex(of: "--gallery") {
    guard CommandLine.arguments.indices.contains(flag + 1) else { fatalError("Usage: Mnome --gallery DIR") }
    do { try Gallery.render(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])); exit(0) } catch { fatalError("Gallery failed: \(error)") }
 }
 let delegate = Delegate()
 app.delegate = delegate
 app.run()
}
