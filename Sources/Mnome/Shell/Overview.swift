import AppKit
import SwiftUI
import Combine
import MnomeSupport

/// GNOME's overview (`gnome-ref/shell/005`, `017`, `024`): one full-screen panel per display under the top bar.
/// Windows and workspaces are Core Animation layers (`OverviewStageView`); SwiftUI draws only the search, results,
/// app grid and dash, on the main display. The panels take the keyboard without making Mnome the active app.
final class OverviewPanel: NSPanel {
    var escape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { escape() }
}
/// Clicks pass through to the stage below except where the chrome draws something.
final class ChromeHostingView<Content: View>: NSHostingView<Content> {
    var takes: (CGPoint) -> Bool = { _ in false }
    override func hitTest(_ point: NSPoint) -> NSView? { takes(convert(point, from: superview)) ? super.hitTest(point) : nil }
}

/// What the SwiftUI chrome watches: a handful of changes per opening, never per frame.
@MainActor final class OverviewStage: ObservableObject {
    @Published var shown = false
    @Published var apps = false
    @Published var selected: Int?
    @Published var page = 0
}
extension Animation {
    static let overview = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.25)
}

@MainActor final class OverviewController {
    let stage = OverviewStage(), captures = WindowCaptures(), files = FileSearch(), wallpapers = Wallpapers()
    private var panels: [OverviewPanel] = [], stages: [OverviewStageView] = [], watches: [AnyCancellable] = []
    private var chromeView: NSView?
    private(set) var isOpen = false
    private(set) var snapshot = OverviewSnapshot()
    private var selectedWindow: UInt64?, leaving: Task<Void, Never>?
    var model: Model!, windowManager: WindowManager!, dock: DockModel!, topBar: TopBarController!
    private var main: OverviewGeometry? { stages.first?.geometry }

    func toggle(apps: Bool) {
        if !isOpen { open(apps: apps) } else if stage.apps != apps && model.query.isEmpty { setApps(apps) } else { close() }
    }
    func open(apps: Bool) {
        leaving?.cancel(); panels.forEach { $0.orderOut(nil) }; panels = []; stages = []; watches = []
        isOpen = true; stage.apps = apps; stage.selected = nil; stage.page = 0; selectedWindow = nil; model.query = ""
        snapshot = makeSnapshot(); wallpapers.load()
        let shown = snapshot.windows.filter { windowManager.state?.isShown($0.id) ?? false }.map(\.id)
        captures.refresh(shown + snapshot.windows.map(\.id).filter { !shown.contains($0) })
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        for (index, screen) in NSScreen.screens.enumerated() {
            let geometry = OverviewGeometry(id: WindowManager.displayID(screen), size: screen.frame.size, origin: CGPoint(x: screen.frame.minX, y: mainHeight - screen.frame.maxY),
                                            bar: topBar.enabled ? topBar.frame(on: screen).height : screen.safeAreaInsets.top, main: index == 0)
            let panel = OverviewPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.level = NSWindow.Level(rawValue: 20); panel.becomesKeyOnlyIfNeeded = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.escape = { [weak self] in self?.escape() }
            let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            let view = OverviewStageView(geometry: geometry); view.controller = self; view.autoresizingMask = [.width, .height]
            view.setWallpaper(wallpapers.images[geometry.id]); view.update(snapshot, images: captures.images, duration: 0)
            container.addSubview(view); stages.append(view)
            if geometry.main {
                let chrome = ChromeHostingView(rootView: OverviewChrome(geometry: geometry, stage: stage, model: model, files: files, dock: dock, controller: self))
                chrome.frame = container.bounds; chrome.autoresizingMask = [.width, .height]
                chrome.takes = { [weak self] point in self?.chromeTakes(point, geometry) ?? false }
                chrome.wantsLayer = true; chrome.alphaValue = 0; chromeView = chrome
                container.addSubview(chrome); panel.initialFirstResponder = chrome
            }
            panel.contentView = container; panel.setFrame(screen.frame, display: true); panel.orderFrontRegardless()
            if geometry.main { panel.makeKey(); DispatchQueue.main.async { Self.focusField(in: panel) } } // typing goes to the search entry
            panels.append(panel)
        }
        topBar.status.inOverview = true
        if let view = stages.first { FrameMeter.shared.begin(apps ? "open-apps" : "open", on: view) }
        for view in stages { view.set(progress: 1, apps: apps, duration: 0.25) }
        stage.shown = true; fadeChrome(to: 1)
        watches = [
            windowManager.$state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() },
            captures.$images.receive(on: DispatchQueue.main).sink { [weak self] images in self?.stages.forEach { $0.setImages(images) } },
            captures.$info.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in guard let self else { return }; self.snapshot = self.makeSnapshot() },
            wallpapers.$images.receive(on: DispatchQueue.main).sink { [weak self] images in self?.stages.forEach { $0.setWallpaper(images[$0.geometry.id]) } },
        ]
    }
    /// `then` runs at once, under the closing animation.
    func close(then: (() -> Void)? = nil) {
        guard isOpen else { then?(); return }
        isOpen = false; leaving?.cancel(); watches = []; then?()
        let closing = panels, views = stages
        if let view = views.first { FrameMeter.shared.begin("close", on: view) }
        fadeChrome(to: 0)
        var left = views.count
        for view in views { view.set(progress: 0, apps: false, duration: 0.25) { [weak self] in
            left -= 1; guard left == 0 else { return }
            closing.forEach { $0.orderOut(nil) }
            guard let self, !self.isOpen else { return }
            self.panels = []; self.stages = []; self.chromeView = nil; self.stage.shown = false; self.topBar.status.inOverview = false; self.model.query = ""
        } }
    }
    /// SwiftUI's own focus request is lost when the panel becomes key after it; the field itself takes the keyboard.
    private static func focusField(in panel: NSPanel) {
        func find(_ view: NSView) -> NSTextField? { (view as? NSTextField).flatMap { $0.isEditable ? $0 : nil } ?? view.subviews.lazy.compactMap(find).first }
        if let field = panel.contentView.flatMap(find) { panel.makeFirstResponder(field) }
    }
    /// The search, dash and grid fade as one layer, on the GPU: SwiftUI does nothing while it runs.
    private func fadeChrome(to alpha: CGFloat) {
        guard let chromeView else { return }
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.25; context.timingFunction = .overview; chromeView.animator().alphaValue = alpha }
    }
    func escape() { if !model.query.isEmpty { model.query = "" } else { close() } }
    private func setApps(_ apps: Bool) {
        stage.apps = apps; stage.selected = nil
        for view in stages { view.set(progress: 1, apps: apps, duration: 0.25) }
    }

    // MARK: The engine, underneath

    private func makeSnapshot() -> OverviewSnapshot {
        guard let state = windowManager.state else { return OverviewSnapshot() }
        var byBundle: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications { if let id = app.bundleIdentifier, byBundle[id] == nil { byBundle[id] = app } }
        let windows = state.windows.filter { !$0.hidden && !$0.fullscreen }.map { w -> OverviewWindow in
            let info = captures.info[w.id], app = info.flatMap { NSRunningApplication(processIdentifier: $0.pid) } ?? byBundle[w.app]
            return OverviewWindow(id: w.id, workspace: w.workspace, display: w.display, rect: w.rect, minimized: w.minimized, sticky: w.sticky, title: info?.title ?? app?.localizedName ?? "Window", appName: app?.localizedName ?? "", icon: IconCache.icon(app))
        }
        return OverviewSnapshot(workspaces: state.workspaces, current: state.current, workspacesOn: state.workspacesOn, windows: windows)
    }
    /// The engine moved something: a workspace switch slides, anything else settles in 200 ms.
    private func refresh() {
        guard isOpen else { return }
        let before = snapshot.current
        snapshot = makeSnapshot()
        let slide = snapshot.current != before
        for view in stages { view.update(snapshot, images: captures.images, duration: slide ? 0.25 : 0.2, timing: slide ? .workspace : .overview) }
        if slide { selectedWindow = nil; stages.forEach { $0.select(nil) } }
    }
    /// A window on the current workspace is raised at once. One elsewhere: the overview slides to its workspace and
    /// stays up until the engine has put every window in place, so nothing is seen moving afterwards.
    func choose(_ id: UInt64) {
        guard let window = snapshot.windows.first(where: { $0.id == id }) else { close(); return }
        if window.workspace == snapshot.current || window.sticky || !snapshot.workspacesOn { close { _ = self.windowManager.focus(id) }; return }
        _ = windowManager.focus(id)
        leave()
    }
    func enter(_ workspace: UInt64) {
        if workspace != snapshot.current { windowManager.send(.setWorkspace(workspace)) }
        leave()
    }
    private func leave() {
        leaving?.cancel()
        leaving = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30)) // the engine's first moves begin
            guard let self, !Task.isCancelled else { return }
            _ = await self.windowManager.settled(timeout: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.close()
        }
    }
    func switchWorkspace(_ direction: Int) {
        guard isOpen, snapshot.workspacesOn, windowManager.running else { return }
        windowManager.send(.stepWorkspace(direction))
    }
    func turnPage(_ direction: Int) {
        guard let main else { return }
        let grid = AppGrid(area: main.gridArea, count: model.apps.count)
        withAnimation(.overview) { stage.page = min(grid.pages - 1, max(0, stage.page + direction)) }
    }
    func move(_ id: UInt64, to workspace: UInt64) { windowManager.send(.toWorkspace(id, workspace)) }
    func closeWindow(_ id: UInt64) { windowManager.registry.close(id); captures.forget(id) }
    func launch(_ app: AppItem) { close { NSWorkspace.shared.openApplication(at: app.url, configuration: .init()) } }
    func open(_ url: URL) { close { NSWorkspace.shared.open(url) } }

    // MARK: Keyboard, through the search entry

    /// The current workspace's windows in reading order.
    private var order: [UInt64] {
        guard let view = stages.first else { return [] }
        let frames = view.windowFrames.filter { id, _ in snapshot.windows.contains { $0.id == id && ($0.workspace == snapshot.current || $0.sticky) } }
        return frames.keys.sorted { (frames[$0]!.midY, frames[$0]!.midX) < (frames[$1]!.midY, frames[$1]!.midX) }
    }
    func stepWindows(_ delta: Int) -> Bool {
        let order = order
        guard !order.isEmpty else { return false }
        let index = selectedWindow.flatMap(order.firstIndex) ?? (delta > 0 ? -1 : order.count)
        selectedWindow = order[(index + delta + order.count) % order.count]
        stages.first?.select(selectedWindow); return true
    }
    func chooseSelected() { if let selectedWindow { choose(selectedWindow) } }
    /// Where the chrome takes clicks: the search entry and dash always; results or the app grid when shown.
    private func chromeTakes(_ point: CGPoint, _ g: OverviewGeometry) -> Bool {
        if g.searchRect.insetBy(dx: -8, dy: -8).contains(point) || point.y >= g.dashTop - 8 { return true }
        if !model.query.isEmpty { return g.resultsArea.contains(point) }
        return stage.apps && g.gridArea.contains(point)
    }
    var windowsForSearch: [OverviewWindow] { snapshot.windows }
}

/// App and file icons, loaded once.
@MainActor enum IconCache {
    private static var icons: [String: NSImage] = [:]
    static func icon(_ app: NSRunningApplication?) -> NSImage? {
        guard let app else { return nil }
        let key = app.bundleURL?.path ?? "pid:\(app.processIdentifier)"
        if let icon = icons[key] { return icon }
        let icon = app.icon; icons[key] = icon; return icon
    }
    static func file(_ path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path); icons[path] = icon; return icon
    }
}

/// Each display's wallpaper, decoded once at screen size off the main thread: a dynamic wallpaper can be 140 MB.
@MainActor final class Wallpapers: ObservableObject {
    @Published private(set) var images: [UInt64: CGImage] = [:]
    private var sources: [UInt64: URL] = [:]
    func load() {
        for screen in NSScreen.screens {
            let id = WindowManager.displayID(screen), pixels = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen), sources[id] != url else { continue }
            sources[id] = url
            Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
                await MainActor.run { self.images[id] = image }
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
struct SearchResults {
    var apps: [OverviewResult] = [], sections: [(title: String, icon: NSImage?, rows: [OverviewResult])] = []
    var all: [OverviewResult] { apps + sections.flatMap(\.rows) }
}

/// The search entry, results, app grid and dash. Results are worked out once per change, not per render.
struct OverviewChrome: View {
    let geometry: OverviewGeometry
    @ObservedObject var stage: OverviewStage
    @ObservedObject var model: Model
    @ObservedObject var files: FileSearch
    @ObservedObject var dock: DockModel
    let controller: OverviewController
    @FocusState private var searchFocused: Bool
    @State private var found = SearchResults()
    private var grid: AppGrid { AppGrid(area: geometry.gridArea, count: model.apps.count) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if !model.query.isEmpty { results }
            else if stage.apps { AppGridView(model: model, stage: stage, grid: grid, launch: controller.launch) }
            searchEntry
            DockView(model: dock).fixedSize().position(x: geometry.size.width / 2, y: geometry.dashTop + geometry.dashHeight / 2)
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark).foregroundStyle(.white)
        .onChange(of: model.query) { _, query in stage.selected = query.isEmpty ? nil : 0; model.search(); files.search(query); found = compute() }
        .onChange(of: model.filtered.map(\.id)) { _, _ in found = compute() }
        .onChange(of: files.results) { _, _ in found = compute() }
    }
    private var searchEntry: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.white.opacity(0.7)).accessibilityHidden(true)
            TextField("", text: $model.query, prompt: Text("Type to search").foregroundStyle(Color.white.opacity(0.55))).textFieldStyle(.plain).font(.adwaita(14.667)).focused($searchFocused)
                .onSubmit(activate).onKeyPress(.leftArrow) { step(-1) }.onKeyPress(.rightArrow) { step(1) }.onKeyPress(.upArrow) { step(-1, vertical: true) }.onKeyPress(.downArrow) { step(1, vertical: true) }
                .onKeyPress(.tab) { step(1) }.onExitCommand { controller.escape() }.accessibilityLabel("Search")
            if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Clear") }
        }
        .padding(.horizontal, 14).frame(width: geometry.searchRect.width, height: geometry.searchRect.height)
        .background(Capsule().fill(Color(red: 69 / 255, green: 69 / 255, blue: 74 / 255)))
        .overlay(Capsule().strokeBorder(ShellPalette.toggleOn.opacity(searchFocused && !model.query.isEmpty ? 1 : 0), lineWidth: 2))
        .position(x: geometry.searchRect.midX, y: geometry.searchRect.midY)
        .onAppear { searchFocused = true }
        .onChange(of: stage.shown) { _, shown in if shown { searchFocused = true } }
    }
    private func step(_ delta: Int, vertical: Bool = false) -> KeyPress.Result {
        if model.query.isEmpty && stage.apps {
            guard grid.count > 0 else { return .ignored }
            let next = min(grid.count - 1, max(0, (stage.selected ?? stage.page * grid.perPage - (delta > 0 ? 1 : 0)) + delta * (vertical ? grid.columns : 1)))
            stage.selected = next; if next / grid.perPage != stage.page { withAnimation(.overview) { stage.page = next / grid.perPage } }
            return .handled
        }
        if model.query.isEmpty { return controller.stepWindows(delta) ? .handled : .ignored }
        let count = found.all.count
        guard count > 0 else { return .ignored }
        stage.selected = min(count - 1, max(0, (stage.selected ?? 0) + delta)); return .handled
    }
    private func activate() {
        if model.query.isEmpty && stage.apps { if let app = model.apps[safe: stage.selected ?? -1] { controller.launch(app) }; return }
        if model.query.isEmpty { controller.chooseSelected(); return }
        if let result = found.all[safe: stage.selected ?? 0] ?? found.all.first { run(result) }
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
    private func compute() -> SearchResults {
        let start = CACurrentMediaTime(), query = model.query
        guard !query.isEmpty else { return SearchResults() }
        var out = SearchResults()
        out.apps = model.filtered.prefix(6).map { OverviewResult(id: "app:\($0.id)", kind: .app($0), title: $0.name, detail: "", icon: IconCache.file($0.url.path)) }
        if let value = Calculator.evaluate(query) {
            let text = Calculator.format(value)
            out.sections.append(("Calculator", IconCache.file("/System/Applications/Calculator.app"), [OverviewResult(id: "sum", kind: .sum(text), title: text, detail: "\(query) =   Return copies it", icon: nil)]))
        }
        let open = controller.windowsForSearch.filter { OverviewContent.matches(query: query, title: $0.title, app: $0.appName) }
        if !open.isEmpty { out.sections.append(("Windows", NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil), open.prefix(5).map { OverviewResult(id: "window:\($0.id)", kind: .window($0.id), title: $0.title, detail: $0.appName, icon: $0.icon) })) }
        let panes = SettingsPane.search(query)
        if !panes.isEmpty { out.sections.append(("Settings", IconCache.file("/System/Applications/System Settings.app"), panes.prefix(5).map { OverviewResult(id: "setting:\($0.pane)", kind: .setting($0), title: $0.name, detail: $0.detail, icon: nil) })) }
        if !files.results.isEmpty { out.sections.append(("Files", IconCache.file("/System/Library/CoreServices/Finder.app"), files.results.map { OverviewResult(id: "file:\($0.path)", kind: .file($0), title: $0.lastPathComponent, detail: $0.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), icon: IconCache.file($0.path)) })) }
        FrameMeter.shared.note(String(format: "search %@ %.1fms", query, (CACurrentMediaTime() - start) * 1000))
        return out
    }
    private var results: some View {
        let selectedID = found.all[safe: stage.selected ?? 0]?.id
        return ZStack(alignment: .top) {
            Color(red: 34 / 255, green: 34 / 255, blue: 38 / 255) // covers the workspaces while searching, as GNOME's
            ScrollView {
                VStack(spacing: 24) {
                    if !found.apps.isEmpty {
                        HStack(spacing: 12) { ForEach(found.apps) { result in
                            Button { run(result) } label: {
                                VStack(spacing: 10) { if let icon = result.icon { Image(nsImage: icon).resizable().frame(width: 96, height: 96) }; Text(result.title).font(.adwaita(14.667)).lineLimit(1) }
                                    .padding(12).frame(width: 145, height: 145).background(RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(result.id == selectedID ? 0.17 : 0)))
                            }.buttonStyle(ShellButtonStyle(radius: 24)).accessibilityLabel(result.title)
                        } }
                    }
                    ForEach(found.sections, id: \.title) { section in
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
            .frame(width: geometry.resultsArea.width, height: geometry.resultsArea.height).offset(y: geometry.resultsArea.minY)
        }
        .frame(width: geometry.size.width, height: geometry.dashTop - 8, alignment: .top)
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
/// GNOME's app grid: pages of icons and page dots. Arrows and Return come through the search entry.
struct AppGridView: View {
    @ObservedObject var model: Model
    @ObservedObject var stage: OverviewStage
    let grid: AppGrid
    let launch: (AppItem) -> Void
    @State private var running: Set<String> = []
    var body: some View {
        let page = min(stage.page, grid.pages - 1), items = Array(model.apps.dropFirst(page * grid.perPage).prefix(grid.perPage)), cell = AppGrid.cell
        VStack(spacing: 12) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<grid.rows, id: \.self) { row in
                    GridRow { ForEach(0..<grid.columns, id: \.self) { column in
                        let index = row * grid.columns + column
                        if let item = items[safe: index] {
                            Button { launch(item) } label: {
                                VStack(spacing: 8) {
                                    Image(nsImage: IconCache.file(item.url.path)).resizable().frame(width: 72, height: 72)
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
        .onAppear { running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }) }
    }
}

extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
