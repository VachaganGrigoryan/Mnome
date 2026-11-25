import AppKit
import ScreenCaptureKit

/// Stills of windows for the overview, kept between openings so it can show something at once.
/// Titles and owners come from the same listing. Without Screen Recording, everything stays empty and the overview shows app icons.
@MainActor final class WindowCaptures: ObservableObject {
    struct Info { let title: String, pid: pid_t }
    /// Handed straight to Core Animation, which keeps them on the GPU.
    @Published private(set) var images: [UInt64: CGImage] = [:]
    @Published private(set) var info: [UInt64: Info] = [:]
    private var running: Task<Void, Never>?
    /// The given windows first, in order; three at a time.
    func refresh(_ ids: [UInt64]) {
        running?.cancel()
        guard CGPreflightScreenCaptureAccess() else { return }
        running = Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false), !Task.isCancelled else { return }
            var byID: [UInt64: SCWindow] = [:]
            for window in content.windows { byID[UInt64(window.windowID)] = window }
            for (id, window) in byID where ids.contains(id) { if let app = window.owningApplication { info[id] = Info(title: window.title?.isEmpty == false ? window.title! : app.applicationName, pid: app.processID) } }
            let wanted = ids.compactMap { id in byID[id].map { (id, $0) } }
            await withTaskGroup(of: (UInt64, CGImage?).self) { group in
                var next = 0
                func add() { guard next < wanted.count else { return }; let (id, window) = wanted[next]; next += 1; group.addTask { (id, await Self.capture(window)) } }
                for _ in 0..<3 { add() }
                for await (id, image) in group {
                    if Task.isCancelled { group.cancelAll(); return }
                    if let image { images[id] = image }
                    add()
                }
            }
        }
    }
    func forget(_ id: UInt64) { images[id] = nil; info[id] = nil }
    /// Twice the window's point size at most, and no side over 1600 px.
    nonisolated private static func capture(_ window: SCWindow) async -> CGImage? {
        let config = SCStreamConfiguration(), longest = max(window.frame.width, window.frame.height), scale = min(2, 1600 / max(1, longest))
        config.width = max(1, Int(window.frame.width * scale)); config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
    }
}
