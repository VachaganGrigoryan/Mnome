import AppKit
import CoreWLAN
import IOKit.pwr_mgt
import MnomeSupport

/// The Mac settings quick settings switches. Each reads back after a change, so a refused one shows its real state.
@MainActor final class SystemControls: ObservableObject {
    @Published private(set) var brightness: Double?
    @Published private(set) var wifiOn: Bool?
    @Published private(set) var bluetoothOn: Bool?
    @Published private(set) var nightLight: Bool?
    @Published private(set) var darkStyle: Bool?
    @Published private(set) var keepAwake = false
    private var assertion = IOPMAssertionID(0)
    /// The built-in display: the only one macOS sets brightness on.
    var builtIn: CGDirectDisplayID? { NSScreen.screens.map { CGDirectDisplayID(WindowManager.displayID($0)) }.first { CGDisplayIsBuiltin($0) != 0 } }
    func refresh() {
        brightness = builtIn.flatMap(Private.brightness).map(Double.init)
        wifiOn = CWWiFiClient.shared().interface()?.powerOn()
        bluetoothOn = Private.bluetoothOn; nightLight = Private.nightLight?.on; darkStyle = Private.darkStyle
    }
    @discardableResult func setBrightness(_ value: Double) -> Bool {
        guard let id = builtIn, Private.setBrightness(id, Float(min(1, max(0, value)))) else { return false }
        brightness = Private.brightness(id).map(Double.init); return true
    }
    func setWifi(_ on: Bool) { try? CWWiFiClient.shared().interface()?.setPower(on); settle() }
    func setBluetooth(_ on: Bool) { _ = Private.setBluetooth(on); settle() }
    func setNightLight(_ on: Bool) { _ = Private.setNightLight(on); settle() }
    func setDarkStyle(_ on: Bool) { Private.setDarkStyle(on); settle() }
    func setKeepAwake(_ on: Bool) {
        if on, !keepAwake { keepAwake = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Mnome: Keep Awake" as CFString, &assertion) == kIOReturnSuccess }
        else if !on, keepAwake { IOPMAssertionRelease(assertion); keepAwake = false }
    }
    /// Radios take a moment to change; read now and again shortly after.
    private func settle() { refresh(); Task { try? await Task.sleep(for: .seconds(1)); refresh() } }
}

/// Suspend, restart, power off and log out, asked of loginwindow as Apple documents (QA1134), so apps get to save.
enum Session {
    static func perform(_ action: SessionAction) -> Bool {
        let code: AEEventID = switch action { case .suspend: AEEventID(kAESleep); case .restart: AEEventID(kAERestart); case .powerOff: AEEventID(kAEShutDown); case .logOut: AEEventID(kAEReallyLogOut) }
        guard let loginwindow = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first else { return false }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: code, targetDescriptor: NSAppleEventDescriptor(processIdentifier: loginwindow.processIdentifier), returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        do { try event.sendEvent(options: [.noReply], timeout: 10); return true } catch { NSLog("Mnome: \(action.title) was refused: \(error)"); return false }
    }
}
