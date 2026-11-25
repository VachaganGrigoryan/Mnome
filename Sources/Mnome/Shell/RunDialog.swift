import AppKit
import SwiftUI
import MnomeSupport

/// GNOME's "Run a Command" (Option+F2). An application's name opens it; anything else runs in a login shell,
/// detached, so it outlives the dialog. "r" restarts Mnome.
struct RunDialogView: View {
    let close: () -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var back = -1
    @FocusState private var focused: Bool
    @AppStorage("runHistory") private var stored = ""
    private var history: [String] { stored.split(separator: "\n").map(String.init) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Run a Command").font(.adwaita(20, .heavy)).frame(maxWidth: .infinity).padding(.bottom, 2)
            TextField("", text: $text).textFieldStyle(.plain).font(.adwaita(14.667)).focused($focused)
                .padding(.horizontal, 10).frame(height: 42).background(RoundedRectangle(cornerRadius: 9).fill(ShellPalette.ink(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ShellPalette.toggleOn.opacity(focused ? 1 : 0), lineWidth: 2))
                .onSubmit(submit).onKeyPress(.upArrow) { recall(1) }.onKeyPress(.downArrow) { recall(-1) }
                .accessibilityLabel("Command")
            Text(error ?? "Press ESC to close").font(.adwaita(12)).foregroundStyle(error == nil ? ShellPalette.dim : Color(nsColor: .systemRed))
        }
        .padding(.horizontal, 24).padding(.vertical, 34).frame(width: 400).background(ShellPalette.popover).clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(ShellPalette.popoverBorder, lineWidth: 1))
        .onAppear { focused = true }.onExitCommand(perform: close)
    }
    private func recall(_ step: Int) -> KeyPress.Result {
        let next = back + step
        guard next >= -1, next < history.count else { return .handled }
        back = next; text = next < 0 ? "" : history[next]; return .handled
    }
    private func submit() {
        let command = RunCommand(text)
        guard command != .nothing else { return }
        stored = RunCommand.remember(text, in: history).joined(separator: "\n"); back = -1
        switch command {
        case .nothing: return
        case .restartShell: close(); Runner.restartMnome()
        case .command(let line):
            if let app = Runner.application(named: line) { NSWorkspace.shared.openApplication(at: app, configuration: .init()); close(); return }
            error = nil
            Task { if let failure = await Runner.shell(line) { error = failure } else { close() } }
        }
    }
}
enum Runner {
    static func application(named name: String) -> URL? {
        guard !name.contains(" ") || name.hasSuffix(".app") else { return nil }
        let wanted = (name.hasSuffix(".app") ? name : name + ".app").lowercased(), fm = FileManager.default
        for folder in ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
            if let hit = (try? fm.contentsOfDirectory(atPath: folder))?.first(where: { $0.lowercased() == wanted }) { return URL(fileURLWithPath: folder).appendingPathComponent(hit) }
        }
        return nil
    }
    /// Nil once it started; otherwise what to tell the person. The command itself keeps running after the shell leaves.
    static func shell(_ line: String) async -> String? {
        let word = line.split(separator: " ").first.map(String.init) ?? line, quoted = "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v -- \(quoted) >/dev/null 2>&1 || exit 127; { \(line) } >/dev/null 2>&1 </dev/null &!"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let status: Int32? = await withCheckedContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { process.terminationHandler = nil; done.resume(returning: nil) }
        }
        guard let status else { return "The shell could not start" }
        return switch status { case 0: nil; case 127: "No such command “\(word)”"; default: "The command could not start" }
    }
    /// Quits as usual (which puts the Mac back) and starts again once this process is gone.
    @MainActor static func restartMnome() {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        try? process.run(); NSApp.terminate(nil)
    }
}
