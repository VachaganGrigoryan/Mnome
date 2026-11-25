import AppKit

// "Show Applications" in the Mac Dock: Mnome toggles its app grid, as GNOME's dash button does.
// Lives in Mnome.app/Contents/Library, so Mnome is three folders up; started if it is not running.
let mnome = "dev.mnome.shell"
if NSRunningApplication.runningApplications(withBundleIdentifier: mnome).isEmpty {
    let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in exit(0) }
    RunLoop.main.run(until: Date().addingTimeInterval(10))
} else {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("dev.mnome.showApplications"), object: nil, userInfo: nil, deliverImmediately: true)
}
exit(0)
