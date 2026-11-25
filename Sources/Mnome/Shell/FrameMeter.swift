import AppKit
import QuartzCore

/// Times the overview while `defaults write dev.mnome.shell overviewTiming -bool true`: from the request to the
/// first frame, and every frame for half a second after, one line per opening in `overview-timing.log`.
@MainActor final class FrameMeter: NSObject {
    static let shared = FrameMeter()
    nonisolated static var file: URL { WindowManager.defaultJournal.deletingLastPathComponent().appendingPathComponent("overview-timing.log") }
    private var link: CADisplayLink?, start = 0.0, stamps: [CFTimeInterval] = [], label = ""
    var enabled: Bool { CFPreferencesAppSynchronize("dev.mnome.shell" as CFString); return UserDefaults.standard.bool(forKey: "overviewTiming") }
    func begin(_ label: String, on view: NSView) {
        guard enabled else { return }
        link?.invalidate(); self.label = label; start = CACurrentMediaTime(); stamps = []
        let link = (view.window?.screen ?? NSScreen.screens[0]).displayLink(target: self, selector: #selector(tick(_:))); link.add(to: .main, forMode: .common); self.link = link // the display's, so a closing panel does not stop it
    }
    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        guard CACurrentMediaTime() - start > 0.5 else { return }
        link.invalidate(); self.link = nil
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }, frame = link.targetTimestamp - link.timestamp
        let dropped = gaps.filter { $0 > frame * 1.5 }.count
        write(String(format: "%@ first=%.0fms frames=%d worst=%.1fms dropped=%d hz=%.0f", label, ((stamps.first ?? start) - start) * 1000, stamps.count, (gaps.max() ?? 0) * 1000, dropped, 1 / max(frame, 0.001)))
    }
    func note(_ line: String) { if enabled { write(line) } }
    private func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: Self.file) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() } else { try? data.write(to: Self.file) }
    }
}
