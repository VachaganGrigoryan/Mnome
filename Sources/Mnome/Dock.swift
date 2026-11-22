import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MnomeSupport

struct DockItem: Identifiable, Equatable { let id: String; let name: String; let url: URL; let pinned: Bool; let running: Bool }
@MainActor final class DockModel: ObservableObject {
    @Published var items: [DockItem] = []
    @Published var favorites: [Favorite] = []
    var changed: (() -> Void)?
    var beforeOpen: (() -> Void)?
    var showApps: (() -> Void)?
    private let store = FavoritesStore()
    private var observers: [NSObjectProtocol] = []
    private var revision = UUID()
    private static var identities: [URL: String] = [:] // every app switch asks for all of them
    static func identity(_ url: URL) -> String {
        if let known = identities[url] { return known }
        let id = Bundle(url: url)?.bundleIdentifier ?? url.standardizedFileURL.path; identities[url] = id; return id
    }
    func start() {
        favorites = store.load {
            ["com.apple.finder", "com.apple.Safari", "com.apple.Terminal", "com.apple.systempreferences"].compactMap { id in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
                return Favorite(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), path: url.path)
            }
        }
        for notification in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        }
        refresh()
    }
    func stop() { revision = UUID(); observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = [] }
    func resolved(_ favorite: Favorite) -> URL? {
        FavoritesStore.resolvedPath(favorite, lookup: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }, exists: { Bundle(path: $0)?.bundleURL.pathExtension == "app" }).map { URL(fileURLWithPath: $0) }
    }
    func isPinned(_ url: URL) -> Bool { favorites.contains { $0.id == Self.identity(url) } }
    func togglePin(_ url: URL, name: String) {
        let id = Self.identity(url)
        if favorites.contains(where: { $0.id == id }) { favorites.removeAll { $0.id == id } }
        else { favorites.append(Favorite(id: id, name: name, path: url.path)) }
        save()
    }
    func remove(_ id: String) { favorites.removeAll { $0.id == id }; save() }
    func move(_ id: String, before target: String) { favorites = FavoritesStore.reordered(favorites, moving: id, before: target); save() }
    func moveBy(_ id: String, offset: Int) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        let destination = max(0, min(favorites.count - 1, index + offset))
        guard destination != index else { return }
        let value = favorites.remove(at: index); favorites.insert(value, at: destination); save()
    }
    func moveToStart(_ id: String) { if let first = favorites.first { move(id, before: first.id) } }
    func moveToEnd(_ id: String) { favorites = FavoritesStore.movedToEnd(favorites, id: id); save() }
    private func save() { store.save(favorites); changed?(); refresh() }
    func refresh() {
        revision = UUID(); let current = revision
        let pinned = favorites.compactMap { favorite -> (Favorite, URL)? in resolved(favorite).map { (favorite, $0) } }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        var urls: [String: URL] = [:]
        let pinnedInput = pinned.map { favorite, url -> [String: String] in urls[favorite.id] = url; return ["id": favorite.id, "name": favorite.name] }
        let runningInput = running.compactMap { app -> [String: String]? in guard let url = app.bundleURL else { return nil }; let id = Self.identity(url); if urls[id] == nil { urls[id] = url }; return ["id": id, "name": app.localizedName ?? url.deletingPathExtension().lastPathComponent] }
        let lookup = urls
        DispatchQueue.global(qos: .userInitiated).async {
            let response = core(["version": 1, "op": "dock", "favorites": pinnedInput, "running": runningInput])
            let result = (response["items"] as? [[String: Any]] ?? []).compactMap { value -> DockItem? in
                guard let id = value["id"] as? String, let url = lookup[id], let name = value["name"] as? String else { return nil }
                return DockItem(id: id, name: name, url: url, pinned: value["pinned"] as? Bool ?? false, running: value["running"] as? Bool ?? false)
            }
            Task { @MainActor in guard self.revision == current, self.items != result else { return }; self.items = result; self.changed?() }
        }
    }
    func open(_ item: DockItem) {
        beforeOpen?()
        NSWorkspace.shared.openApplication(at: item.url, configuration: .init()) { _, error in
            if let error { Task { @MainActor in let alert = NSAlert(); alert.messageText = "Could not open \(item.name)"; alert.informativeText = error.localizedDescription; alert.runModal() } }
        }
    }
    func quit(_ item: DockItem) { NSWorkspace.shared.runningApplications.filter { $0.bundleURL.map(Self.identity) == item.id }.forEach { $0.terminate() } }
}
struct DockView: View {
    @ObservedObject var model: DockModel
    @State private var dragging: String?
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.items) { item in
                    if !item.pinned, model.items.first(where: { !$0.pinned })?.id == item.id, model.items.contains(where: \.pinned) { Divider().frame(height: 40).overlay(Color.white.opacity(0.2)) }
                    Button { model.open(item) } label: {
                        VStack(spacing: 3) { Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 48, height: 48); Circle().fill(item.running ? Color.white : .clear).frame(width: 4, height: 4) }.padding(4)
                    }.buttonStyle(ShellButtonStyle(radius: 12)).help(item.name).accessibilityLabel("\(item.name)\(item.running ? ", running" : "")")
                    .contextMenu {
                        Button(item.running ? "Activate" : "Open") { model.open(item) }
                        Button(item.pinned ? "Unpin from Dash" : "Pin to Dash") { model.togglePin(item.url, name: item.name) }
                        if item.pinned {
                            Button("Move Left") { model.moveBy(item.id, offset: -1) }.disabled(model.favorites.first?.id == item.id)
                            Button("Move Right") { model.moveBy(item.id, offset: 1) }.disabled(model.favorites.last?.id == item.id)
                            Button("Move First") { model.moveToStart(item.id) }.disabled(model.favorites.first?.id == item.id)
                            Button("Move Last") { model.moveToEnd(item.id) }.disabled(model.favorites.last?.id == item.id)
                        }
                        if item.running { Button("Quit") { model.quit(item) } }
                    }
                    .modifier(FavoriteDrag(id: item.id, enabled: item.pinned, dragging: $dragging))
                    .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                        guard item.pinned, let provider = providers.first else { return false }
                        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                            guard let id = object as? String else { return }; Task { @MainActor in model.move(id, before: item.id); dragging = nil }
                        }; return true
                    }
                }
                if dragging != nil {
                    Image(systemName: "arrow.right.to.line").foregroundStyle(.secondary).frame(width: 24, height: 48).help("Drop a favorite here to move it to the end")
                    .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                        guard let provider = providers.first else { return false }
                        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                            guard let id = object as? String else { return }; Task { @MainActor in model.moveToEnd(id); dragging = nil }
                        }; return true
                    }
                }
                if model.items.isEmpty { Text("Pin apps from the launcher").font(.caption).padding(8) }
                Divider().frame(height: 40).overlay(Color.white.opacity(0.2))
                Button { model.showApps?() } label: { Image(systemName: "square.grid.3x3.fill").font(.system(size: 24)).frame(width: 48, height: 48).padding(4) }
                    .buttonStyle(ShellButtonStyle(radius: 12)).help("Show Applications").accessibilityLabel("Show Applications")
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }.onDrop(of: [UTType.text], delegate: DockDragExit(dragging: $dragging)).scrollIndicators(.hidden).background(ShellPalette.dash).clipShape(RoundedRectangle(cornerRadius: 24)).shellTheme()
    }
}
@MainActor final class DockController {
    let model = DockModel()
    var changed: (() -> Void)?
    var enabled: Bool { UserDefaults.standard.object(forKey: "showDock") as? Bool ?? true }
    private var panels: [TopBarPanel] = []
    private var displayIDs: [String] = []
    private var observer: NSObjectProtocol?
    func start() {
        model.changed = { [weak self] in self?.rebuild(); self?.changed?() }; model.start(); rebuild()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.rebuild() } }
    }
    func setVisible(_ visible: Bool) { UserDefaults.standard.set(visible, forKey: "showDock"); rebuild() }
    func rebuild() {
        let ids = NSScreen.screens.map { String(describing: $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]) }
        if enabled && ids == displayIDs && panels.count == NSScreen.screens.count {
            for (panel, screen) in zip(panels, NSScreen.screens) { panel.setFrame(DockGeometry.frame(visible: screen.visibleFrame, count: model.items.count + 1), display: true) }
            return
        }
        panels.forEach { $0.close() }; panels = []; displayIDs = ids; guard enabled else { return }
        for screen in NSScreen.screens {
            let panel = TopBarPanel(contentRect: DockGeometry.frame(visible: screen.visibleFrame, count: model.items.count + 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .stationary]; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.contentView = NSHostingView(rootView: DockView(model: model)); panel.orderFrontRegardless(); panels.append(panel)
        }
    }
    func focus() { panels.first?.takeKeyboard() }
    func stop() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil; model.stop(); panels.forEach { $0.close() }; panels = [] }
}

struct FavoriteDrag: ViewModifier {
    let id: String; let enabled: Bool; @Binding var dragging: String?
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.onDrag { dragging = id; return NSItemProvider(object: id as NSString) }.onExitCommand { dragging = nil } } else { content }
    }
}

struct DockDragExit: DropDelegate {
    @Binding var dragging: String?
    func dropExited(info: DropInfo) { dragging = nil }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return false }
}
