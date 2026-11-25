import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MnomeSupport

/// GNOME's overview (`gnome-ref/shell/005`, `017`, `024`). One full-screen panel per display under the top bar.
/// It takes the keyboard without making Mnome the active app, so closing it leaves the person where they were.
final class OverviewPanel: NSPanel {
    var escape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { escape() }
}

@MainActor final class OverviewStage: ObservableObject {
    /// 0 is the desktop, 1 the overview; every rect is a function of it.
    @Published var progress: CGFloat = 0
    @Published var apps = false
    @Published var hovered: UInt64?
    @Published var selected: Int?
    @Published var page = 0
}

/// GNOME's curves: ease-out-quad for the overview, ease-out-cubic for workspaces.
extension Animation {
    static let overview = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.25)
    static let workspace = Animation.timingCurve(0.215, 0.61, 0.355, 1, duration: 0.25)
}

struct OverviewScreen {
    let id: UInt64, size: CGSize, origin: CGPoint, bar: CGFloat, main: Bool
    /// From the engine's global coordinates (top-left of the main display, y down) to this panel's.
    func local(_ r: WMRect) -> CGRect { CGRect(x: CGFloat(r.x) - origin.x, y: CGFloat(r.y) - origin.y, width: CGFloat(r.w), height: CGFloat(r.h)) }
    var workArea: CGRect { CGRect(x: 0, y: bar, width: size.width, height: size.height - bar) }
}

@MainActor final class OverviewController {
    let stage = OverviewStage(), captures = WindowCaptures(), files = FileSearch(), wallpapers = Wallpapers()
    private var panels: [OverviewPanel] = []
    private(set) var isOpen = false
    var model: Model!, windowManager: WindowManager!, dock: DockModel!, topBar: TopBarController!

    func toggle(apps: Bool) {
        if !isOpen { open(apps: apps) } else if stage.apps != apps && model.query.isEmpty { withAnimation(.overview) { stage.apps = apps } } else { close() }
    }
    func open(apps: Bool) {
        panels.forEach { $0.orderOut(nil) }; panels = []
        isOpen = true; stage.apps = apps; stage.progress = 0; stage.selected = nil; stage.page = 0; model.query = ""
        wallpapers.load()
        let state = windowManager.state
        if let state {
            let shown = state.windows.filter { state.isShown($0.id) }.map(\.id), rest = state.windows.map(\.id).filter { !shown.contains($0) }
            captures.refresh(shown + rest)
        }
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        for (index, screen) in NSScreen.screens.enumerated() {
            let info = OverviewScreen(id: WindowManager.displayID(screen), size: screen.frame.size, origin: CGPoint(x: screen.frame.minX, y: mainHeight - screen.frame.maxY),
                                      bar: topBar.enabled ? topBar.frame(on: screen).height : screen.safeAreaInsets.top, main: index == 0)
            let panel = OverviewPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.level = NSWindow.Level(rawValue: 20); panel.becomesKeyOnlyIfNeeded = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.escape = { [weak self] in self?.escape() }
            panel.contentView = NSHostingView(rootView: OverviewView(screen: info, stage: stage, captures: captures, files: files, wallpapers: wallpapers, model: model, dock: dock, windows: windowManager, controller: self))
            panel.setFrame(screen.frame, display: true); panel.orderFrontRegardless(); if info.main { panel.makeKey() }
            panels.append(panel)
        }
        topBar.status.inOverview = true
        DispatchQueue.main.async { withAnimation(.overview) { self.stage.progress = 1 } }
    }
    /// `then` runs at once, under the closing animation: a chosen window is raised while the overview flies back to it.
    func close(then: (() -> Void)? = nil) {
        guard isOpen else { then?(); return }
        isOpen = false; then?()
        let closing = panels
        withAnimation(.overview) { stage.progress = 0 } completion: { [weak self] in
            closing.forEach { $0.orderOut(nil) }
            guard let self, !self.isOpen else { return }
            self.panels = []; self.topBar.status.inOverview = false; self.model.query = ""
        }
    }
    func escape() { if !model.query.isEmpty { model.query = "" } else { close() } }
    func choose(_ id: UInt64) { close { _ = self.windowManager.focus(id) } }
    /// Clicking a workspace goes to it, as GNOME.
    func enter(_ workspace: UInt64) { close { if self.windowManager.state?.current != workspace { self.windowManager.send(.setWorkspace(workspace)) } } }
    func move(_ id: UInt64, to workspace: UInt64) { windowManager.send(.toWorkspace(id, workspace)) }
    func closeWindow(_ id: UInt64) { windowManager.registry.close(id); captures.forget(id) }
    func launch(_ app: AppItem) { close { NSWorkspace.shared.openApplication(at: app.url, configuration: .init()) } }
    func open(_ url: URL) { close { NSWorkspace.shared.open(url) } }
}

/// Each display's wallpaper, decoded once at screen size off the main thread: a dynamic wallpaper can be 140 MB.
@MainActor final class Wallpapers: ObservableObject {
    @Published private(set) var images: [UInt64: NSImage] = [:]
    private var sources: [UInt64: URL] = [:]
    /// Cheap when nothing changed; a changed wallpaper shows once it is decoded.
    func load() {
        for screen in NSScreen.screens {
            let id = WindowManager.displayID(screen), pixels = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen), sources[id] != url else { continue }
            sources[id] = url
            Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
                let picture = NSImage(cgImage: image, size: .zero)
                await MainActor.run { self.images[id] = picture }
            }
        }
    }
}

/// Spotlight, for the Files results: names only, in the home folder, five at most.
@MainActor final class FileSearch: ObservableObject {
    @Published private(set) var results: [URL] = []
    private var query: NSMetadataQuery?, observer: NSObjectProtocol?, pending: Task<Void, Never>?
    func search(_ text: String) {
        pending?.cancel(); query?.stop()
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3 else { results = []; return }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(200)); guard !Task.isCancelled else { return }
            let query = NSMetadataQuery(); self.query = query
            query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text); query.searchScopes = [NSMetadataQueryUserHomeScope]
            query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    query.disableUpdates(); defer { query.stop() }
                    self?.results = (0..<min(5, query.resultCount)).compactMap { (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }.map(URL.init(fileURLWithPath:))
                }
            }
            query.start()
        }
    }
}

/// One search result, flattened so arrows and Return move through all of them.
struct OverviewResult: Identifiable {
    enum Kind { case app(AppItem), window(UInt64), setting(SettingsPane), file(URL), sum(String) }
    let id: String, kind: Kind, title: String, detail: String, icon: NSImage?
}

struct OverviewView: View {
    let screen: OverviewScreen
    @ObservedObject var stage: OverviewStage
    @ObservedObject var captures: WindowCaptures
    @ObservedObject var files: FileSearch
    @ObservedObject var wallpapers: Wallpapers
    @ObservedObject var model: Model
    @ObservedObject var dock: DockModel
    @ObservedObject var windows: WindowManager
    let controller: OverviewController
    @FocusState private var searchFocused: Bool
    private var p: CGFloat { stage.progress }
    private var searching: Bool { screen.main && !model.query.isEmpty }
    private var state: WMState? { windows.state }

    // MARK: Geometry (GNOME's, measured at 1280x800)
    private var searchRect: CGRect { CGRect(x: screen.size.width / 2 - 185, y: screen.bar + 12, width: 370, height: 37) }
    private let dashHeight: CGFloat = 86
    private var dashTop: CGFloat { screen.size.height - 12 - dashHeight }
    private var available: CGRect {
        guard screen.main else { return screen.workArea.insetBy(dx: 32, dy: 32) }
        let top = searchRect.maxY + 27
        return CGRect(x: 32, y: top, width: screen.size.width - 64, height: dashTop - 27 - top)
    }
    private var box: CGRect { OverviewLayout.box(workArea: screen.workArea.size, in: available) }
    /// In the app grid the workspaces shrink to a row at the top, as GNOME's.
    private var smallBox: CGRect { OverviewLayout.box(workArea: screen.workArea.size, in: CGRect(x: 0, y: searchRect.maxY + 21, width: screen.size.width, height: screen.size.height * 0.15)) }
    private var workspaceIDs: [UInt64] { screen.main ? (state?.workspaces ?? []) : [state?.current ?? 0] }
    private var currentIndex: Int { screen.main ? (state.flatMap { $0.workspaces.firstIndex(of: $0.current) } ?? 0) : 0 }
    private func frame(ofWorkspace index: Int) -> CGRect {
        let k = CGFloat(index - currentIndex)
        if stage.apps && screen.main {
            let small = smallBox, gap: CGFloat = 24, count = CGFloat(workspaceIDs.count), start = screen.size.width / 2 - (count * small.width + (count - 1) * gap) / 2
            return CGRect(x: start + CGFloat(index) * (small.width + gap), y: small.minY, width: small.width, height: small.height)
        }
        let full = OverviewLayout.lerp(screen.workArea, box, p), shifted = full.offsetBy(dx: k * (full.width + 64), dy: 0)
        let scale = k == 0 ? 1 : 1 - 0.06 * p
        return CGRect(x: shifted.midX - shifted.width * scale / 2, y: shifted.midY - shifted.height * scale / 2, width: shifted.width * scale, height: shifted.height * scale)
    }
    private func members(_ workspace: UInt64) -> [WMState.Window] {
        guard let state else { return [] }
        return state.windows.filter { $0.display == screen.id && !$0.hidden && !$0.fullscreen && (screen.main ? ($0.workspace == workspace || $0.sticky) : true) }
    }
    /// Slots in the overview's own box, then carried with the workspace's frame.
    private func slots(_ workspace: UInt64) -> [UInt64: CGRect] {
        let inner = box.insetBy(dx: 24, dy: 24)
        return OverviewLayout.slots(members(workspace).map { ($0.id, screen.local($0.rect)) }, in: inner, screenHeight: screen.size.height)
    }
    private func place(_ slot: CGRect, in frame: CGRect) -> CGRect {
        let s = frame.width / box.width
        return CGRect(x: frame.minX + (slot.minX - box.minX) * s, y: frame.minY + (slot.minY - box.minY) * s, width: slot.width * s, height: slot.height * s)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ShellPalette.overview.opacity(Double(min(1, p * 4))).contentShape(Rectangle()).onTapGesture { controller.close() }
            ForEach(Array(workspaceIDs.enumerated()), id: \.element) { index, workspace in workspaceView(index, workspace) }
                .opacity(searching || (stage.apps && !screen.main) ? 0 : 1)
            if screen.main {
                searchEntry
                if searching { results.opacity(Double(p)) }
                else if stage.apps { AppGridView(model: model, stage: stage, grid: grid, launch: controller.launch).opacity(Double(p)) }
                DockView(model: dock).fixedSize().position(x: screen.size.width / 2, y: dashTop + dashHeight / 2 + (1 - p) * 60).opacity(Double(p))
            }
        }
        .frame(width: screen.size.width, height: screen.size.height, alignment: .topLeading)
        .animation(.workspace, value: currentIndex).animation(.overview, value: stage.apps)
        .environment(\.colorScheme, .dark).foregroundStyle(.white)
        .onChange(of: model.query) { _, query in stage.selected = query.isEmpty ? nil : 0; model.search(); files.search(query) }
    }

    // MARK: Workspaces and windows
    @ViewBuilder private func workspaceView(_ index: Int, _ workspace: UInt64) -> some View {
        let frame = frame(ofWorkspace: index), current = index == currentIndex, s = frame.width / max(1, screen.workArea.width)
        ZStack(alignment: .topLeading) {
            Group {
                if let wallpaper = wallpapers.images[screen.id] { Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill).frame(width: screen.size.width * s, height: screen.size.height * s).offset(y: -screen.bar * s) }
                else { Color(nsColor: .windowBackgroundColor) }
            }.frame(width: frame.width, height: frame.height, alignment: .topLeading).clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 30 * p)).frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
        .contentShape(RoundedRectangle(cornerRadius: 30 * p)).onTapGesture { current && !stage.apps ? controller.close() : controller.enter(workspace) }
        .onDrop(of: [UTType.text], isTargeted: nil) { providers in drop(providers, on: workspace) }
        .accessibilityElement().accessibilityLabel("Workspace \(index + 1)").accessibilityAddTraits(.isButton)
        let slots = slots(workspace)
        ForEach(members(workspace).filter { slots[$0.id] != nil }, id: \.id) { window in
            let slot = place(slots[window.id]!, in: frame)
            let rect = current && !stage.apps && !window.minimized ? OverviewLayout.lerp(screen.local(window.rect), slot, p) : slot
            windowView(window, rect: rect, showsChrome: !stage.apps && p > 0.99)
                .opacity(window.minimized && current ? Double(p) : 1)
        }
    }
    private func owner(_ window: WMState.Window) -> NSRunningApplication? {
        captures.info[window.id].flatMap { NSRunningApplication(processIdentifier: $0.pid) } ?? NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == window.app }
    }
    private func icon(for window: WMState.Window) -> NSImage? { owner(window)?.icon }
    private func appName(_ window: WMState.Window) -> String { owner(window)?.localizedName ?? "" }
    private func title(_ window: WMState.Window) -> String { captures.info[window.id]?.title ?? owner(window)?.localizedName ?? "Window" }
    @ViewBuilder private func windowView(_ window: WMState.Window, rect: CGRect, showsChrome: Bool) -> some View {
        let hovered = stage.hovered == window.id && showsChrome, selected = stage.selected.flatMap { order[safe: $0] } == window.id && model.query.isEmpty
        ZStack(alignment: .bottom) {
            Group {
                if let image = captures.images[window.id] { Image(nsImage: image).resizable().interpolation(.high) }
                else { RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)).overlay { if let icon = icon(for: window) { Image(nsImage: icon).resizable().frame(width: 64, height: 64) } } }
            }.frame(width: rect.width, height: rect.height).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(hovered || selected ? 0.6 : 0), lineWidth: 3).padding(-6))
            if showsChrome, let icon = icon(for: window) { Image(nsImage: icon).resizable().frame(width: 52, height: 52).offset(y: 14).allowsHitTesting(false) }
        }
        .overlay(alignment: .topTrailing) {
            if hovered { Button { controller.closeWindow(window.id) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26).background(Circle().fill(Color(white: 0.35))) }.buttonStyle(.plain).offset(x: 13, y: -13).accessibilityLabel("Close \(title(window))") }
        }
        .overlay(alignment: .bottom) {
            if hovered { Text(title(window)).font(.adwaita(13, .bold)).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Color(white: 0.2, opacity: 0.9))).frame(maxWidth: rect.width).offset(y: 52).allowsHitTesting(false) }
        }
        .scaleEffect(hovered ? 1.02 : 1).animation(.easeOut(duration: 0.1), value: hovered)
        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle()).onTapGesture { controller.choose(window.id) }
        .onHover { stage.hovered = $0 ? window.id : (stage.hovered == window.id ? nil : stage.hovered) }
        .onDrag { NSItemProvider(object: "\(window.id)" as NSString) }
        .accessibilityElement().accessibilityLabel(title(window)).accessibilityAddTraits(.isButton).accessibilityAction { controller.choose(window.id) }
    }
    private func drop(_ providers: [NSItemProvider], on workspace: UInt64) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { text, _ in
            guard let id = (text as? String).flatMap(UInt64.init) else { return }
            Task { @MainActor in controller.move(id, to: workspace) }
        }
        return true
    }
    /// The current workspace's windows in reading order, for the arrows.
    private var order: [UInt64] {
        guard let state else { return [] }
        let slots = slots(state.current)
        return slots.keys.sorted { (slots[$0]!.midY, slots[$0]!.midX) < (slots[$1]!.midY, slots[$1]!.midX) }
    }

    // MARK: Search
    private var searchEntry: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.white.opacity(0.7)).accessibilityHidden(true)
            TextField("", text: $model.query, prompt: Text("Type to search").foregroundStyle(Color.white.opacity(0.55))).textFieldStyle(.plain).font(.adwaita(14.667)).focused($searchFocused)
                .onSubmit(activate).onKeyPress(.leftArrow) { step(-1) }.onKeyPress(.rightArrow) { step(1) }.onKeyPress(.upArrow) { step(-1, vertical: true) }.onKeyPress(.downArrow) { step(1, vertical: true) }
                .onKeyPress(.tab) { step(1) }.accessibilityLabel("Search")
            if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Clear") }
        }
        .padding(.horizontal, 14).frame(width: searchRect.width, height: searchRect.height)
        .background(Capsule().fill(Color(red: 69 / 255, green: 69 / 255, blue: 74 / 255)))
        .overlay(Capsule().strokeBorder(ShellPalette.toggleOn.opacity(searchFocused && !model.query.isEmpty ? 1 : 0), lineWidth: 2))
        .position(x: searchRect.midX, y: searchRect.midY - (1 - p) * 30).opacity(Double(p))
        .onAppear { searchFocused = true }
    }
    private var grid: AppGrid { AppGrid(area: CGRect(x: 0, y: smallBox.maxY + 30, width: screen.size.width, height: dashTop - smallBox.maxY - 50), count: model.apps.count) }
    private func step(_ delta: Int, vertical: Bool = false) -> KeyPress.Result {
        if stage.apps && model.query.isEmpty {
            guard grid.count > 0 else { return .ignored }
            let next = min(grid.count - 1, max(0, (stage.selected ?? stage.page * grid.perPage - (delta > 0 ? 1 : 0)) + delta * (vertical ? grid.columns : 1)))
            stage.selected = next; if next / grid.perPage != stage.page { withAnimation(.overview) { stage.page = next / grid.perPage } }
            return .handled
        }
        if model.query.isEmpty {
            guard !order.isEmpty else { return .ignored }
            stage.selected = ((stage.selected ?? (delta > 0 ? -1 : order.count)) + delta + order.count) % order.count; return .handled
        }
        let count = flatResults.count
        guard count > 0 else { return .ignored }
        stage.selected = min(count - 1, max(0, (stage.selected ?? 0) + delta)); return .handled
    }
    private func activate() {
        if model.query.isEmpty && stage.apps { if let app = model.apps[safe: stage.selected ?? -1] { controller.launch(app) }; return }
        if model.query.isEmpty { if let i = stage.selected, let id = order[safe: i] { controller.choose(id) }; return }
        guard let result = flatResults[safe: stage.selected ?? 0] ?? flatResults.first else { return }
        run(result)
    }
    private func run(_ result: OverviewResult) {
        switch result.kind {
        case .app(let app): controller.launch(app)
        case .window(let id): controller.choose(id)
        case .setting(let pane): controller.open(URL(string: "x-apple.systempreferences:\(pane.pane)")!)
        case .file(let url): controller.open(url)
        case .sum(let value): NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); controller.close()
        }
    }
    private var flatResults: [OverviewResult] { appResults + sections.flatMap(\.rows) }
    private var appResults: [OverviewResult] { model.filtered.prefix(6).map { OverviewResult(id: "app:\($0.id)", kind: .app($0), title: $0.name, detail: "", icon: NSWorkspace.shared.icon(forFile: $0.url.path)) } }
    private var sections: [(title: String, icon: NSImage?, rows: [OverviewResult])] {
        let query = model.query
        var out: [(String, NSImage?, [OverviewResult])] = []
        if let value = Calculator.evaluate(query) {
            let text = Calculator.format(value)
            out.append(("Calculator", NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app"), [OverviewResult(id: "sum", kind: .sum(text), title: text, detail: "\(query) =   Return copies it", icon: nil)]))
        }
        let open = (state?.windows ?? []).filter { !$0.hidden && OverviewContent.matches(query: query, title: title($0), app: appName($0)) }
        if !open.isEmpty { out.append(("Windows", NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil), open.prefix(5).map { OverviewResult(id: "window:\($0.id)", kind: .window($0.id), title: title($0), detail: appName($0), icon: icon(for: $0)) })) }
        let panes = SettingsPane.search(query)
        if !panes.isEmpty { out.append(("Settings", NSWorkspace.shared.icon(forFile: "/System/Applications/System Settings.app"), panes.prefix(5).map { OverviewResult(id: "setting:\($0.pane)", kind: .setting($0), title: $0.name, detail: $0.detail, icon: nil) })) }
        if !files.results.isEmpty { out.append(("Files", NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app"), files.results.map { OverviewResult(id: "file:\($0.path)", kind: .file($0), title: $0.lastPathComponent, detail: $0.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), icon: NSWorkspace.shared.icon(forFile: $0.path)) })) }
        return out.map { (title: $0.0, icon: $0.1, rows: $0.2) }
    }
    private var results: some View {
        let selectedID = flatResults[safe: stage.selected ?? 0]?.id
        return ScrollView {
            VStack(spacing: 24) {
                if !appResults.isEmpty {
                    HStack(spacing: 12) { ForEach(appResults) { result in
                        Button { run(result) } label: {
                            VStack(spacing: 10) { if let icon = result.icon { Image(nsImage: icon).resizable().frame(width: 96, height: 96) }; Text(result.title).font(.adwaita(14.667)).lineLimit(1) }
                                .padding(12).frame(width: 145, height: 145).background(RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(result.id == selectedID ? 0.17 : 0)))
                        }.buttonStyle(ShellButtonStyle(radius: 24)).accessibilityLabel(result.title)
                    } }
                }
                ForEach(sections, id: \.title) { section in
                    HStack(alignment: .top, spacing: 0) {
                        HStack(spacing: 10) { if let icon = section.icon { Image(nsImage: icon).resizable().frame(width: 32, height: 32) }; Text(section.title).font(.adwaita(14.667)) }.frame(width: 180, alignment: .leading).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) { ForEach(section.rows) { row in
                            Button { run(row) } label: {
                                HStack(spacing: 10) {
                                    if let icon = row.icon { Image(nsImage: icon).resizable().frame(width: 24, height: 24) }
                                    Text(row.title).font(.adwaita(14.667, .bold)).lineLimit(1)
                                    Text(row.detail).font(.adwaita(14.667)).foregroundStyle(Color.white.opacity(0.6)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 10).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(row.id == selectedID ? 0.17 : 0))).contentShape(Rectangle())
                            }.buttonStyle(ShellButtonStyle(radius: 12)).accessibilityLabel("\(row.title), \(row.detail)")
                        } }
                    }.padding(20).frame(maxWidth: 1020).background(RoundedRectangle(cornerRadius: 24).fill(ShellPalette.dash))
                }
            }.padding(.horizontal, 32).frame(maxWidth: .infinity)
        }
        .frame(width: screen.size.width, height: dashTop - searchRect.maxY - 40).offset(y: searchRect.maxY + 20)
    }
}

/// The app grid's shape: 8 columns at most, as many rows as fit.
struct AppGrid {
    let area: CGRect, count: Int
    static let cell = CGSize(width: 136, height: 140)
    var columns: Int { max(3, min(8, Int(area.width * 0.85 / Self.cell.width))) }
    var rows: Int { max(1, Int((area.height - 30) / Self.cell.height)) }
    var perPage: Int { columns * rows }
    var pages: Int { max(1, (count + perPage - 1) / perPage) }
}
/// GNOME's app grid: pages of icons and page dots. Arrows and Return come through the search entry, which holds the keyboard.
struct AppGridView: View {
    @ObservedObject var model: Model
    @ObservedObject var stage: OverviewStage
    let grid: AppGrid
    let launch: (AppItem) -> Void
    var body: some View {
        let page = min(stage.page, grid.pages - 1), items = Array(model.apps.dropFirst(page * grid.perPage).prefix(grid.perPage)), running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }), cell = AppGrid.cell
        VStack(spacing: 12) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<grid.rows, id: \.self) { row in
                    GridRow { ForEach(0..<grid.columns, id: \.self) { column in
                        let index = row * grid.columns + column
                        if let item = items[safe: index] {
                            Button { launch(item) } label: {
                                VStack(spacing: 8) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 72, height: 72)
                                    Text(item.name).font(.adwaita(14.667)).lineLimit(1).truncationMode(.tail)
                                    Circle().fill(running.contains(item.url.path) ? Color.white : .clear).frame(width: 5, height: 5)
                                }.padding(10).frame(width: cell.width - 12, height: cell.height - 12)
                                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(stage.selected == page * grid.perPage + index ? 0.17 : 0)))
                            }.buttonStyle(ShellButtonStyle(radius: 24)).frame(width: cell.width, height: cell.height).help(item.name).accessibilityLabel(item.name)
                        } else { Color.clear.frame(width: cell.width, height: cell.height) }
                    } }
                }
            }.id(page).transition(.push(from: .trailing))
            if grid.pages > 1 {
                HStack(spacing: 10) { ForEach(0..<grid.pages, id: \.self) { i in
                    Button { withAnimation(.overview) { stage.page = i } } label: { Circle().fill(Color.white.opacity(i == page ? 1 : 0.4)).frame(width: 8, height: 8).padding(4) }.buttonStyle(.plain).accessibilityLabel("Page \(i + 1)")
                } }
            }
        }
        .frame(width: grid.area.width, height: grid.area.height).offset(x: grid.area.minX, y: grid.area.minY)
    }
}

extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }

