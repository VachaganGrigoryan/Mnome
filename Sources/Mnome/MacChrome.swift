import AppKit
import MnomeSupport

struct CFPreferencesStore: PreferenceStore {
    /// "domain@currentHost" is the per-Mac layer (`defaults -currentHost`), where System Settings keeps the trackpad's gestures.
    private func application(_ domain: String) -> CFString { let name = Self.name(domain); return name == "NSGlobalDomain" ? kCFPreferencesAnyApplication : name as CFString }
    private static func name(_ domain: String) -> String { domain.hasSuffix(MacElement.currentHost) ? String(domain.dropLast(MacElement.currentHost.count)) : domain }
    private func host(_ domain: String) -> CFString { domain.hasSuffix(MacElement.currentHost) ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost }
    func get(_ domain: String, _ key: String) -> PrefValue {
        guard let value = CFPreferencesCopyValue(key as CFString, application(domain), kCFPreferencesCurrentUser, host(domain)) else { return .absent }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(CFBooleanGetValue((value as! CFBoolean))) }
        if let number = value as? NSNumber { return CFNumberIsFloatType(number) ? .double(number.doubleValue) : .int(number.intValue) }
        if let string = value as? String { return .string(string) }
        return .absent
    }
    func set(_ domain: String, _ key: String, _ value: PrefValue) {
        let stored: CFPropertyList? = switch value {
        case .bool(let v): v as CFBoolean
        case .int(let v): v as CFNumber
        case .double(let v): v as CFNumber
        case .string(let v): v as CFString
        case .absent: nil
        }
        CFPreferencesSetValue(key as CFString, stored, application(domain), kCFPreferencesCurrentUser, host(domain))
        CFPreferencesSynchronize(application(domain), kCFPreferencesCurrentUser, host(domain))
    }
}

/// Hides macOS shell elements while keeping the original values, so they can always be restored.
@MainActor final class MacChromeController: ObservableObject {
    @Published private(set) var hidden: Set<MacElement>
    var changed: (() -> Void)?
    private var snapshot: MacChromeSnapshot
    var needsRestore: Bool { !snapshot.needsRestore.isEmpty }
    private let store = CFPreferencesStore()
    private static let defaultsKey = "macChromeSnapshot"
    init() {
        let saved = UserDefaults.standard.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(MacChromeSnapshot.self, from: $0) } ?? MacChromeSnapshot()
        snapshot = saved; hidden = saved.hidden
    }
    var summary: String { hidden.isEmpty ? "Visible" : hidden.count == MacElement.allCases.count ? "Hidden" : "Partly hidden" }
    /// What the person wants hidden while Mnome runs; Mnome's own bar and dock take the place of these two.
    private var chosen: Set<MacElement> {
        get { UserDefaults.standard.stringArray(forKey: Self.chosenKey).map { Set($0.compactMap(MacElement.init(rawValue:))) } ?? Set(MacElement.allCases) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: Self.chosenKey) }
    }
    private static let chosenKey = "macElementsToHide"
    /// Once: a choice saved before Mission Control, hot corners, animations and tiling existed gets them too, as asked on 25 November 2026.
    func hideChosen() {
        if !UserDefaults.standard.bool(forKey: "macElementsAdded"), UserDefaults.standard.object(forKey: Self.chosenKey) != nil { chosen.formUnion([.missionControl, .hotCorners, .animations, .tiling]) }
        UserDefaults.standard.set(true, forKey: "macElementsAdded")
        let tile = syncDockTile()
        hide(chosen.subtracting(hidden), restartDock: tile)
    }
    private func hide(_ elements: Set<MacElement>, restartDock: Bool = false) {
        guard !elements.isEmpty || restartDock else { return }
        for element in elements { snapshot.capture(element, store: store) }; persist() // originals are on disk before anything is changed
        for element in elements { snapshot.hide(element, store: store) }
        finish(Array(elements), restartDock: restartDock)
    }
    func set(_ element: MacElement, hidden hide: Bool) {
        if hide { chosen.insert(element) } else { chosen.remove(element) }
        if element == .dock { _ = syncDockTile() } // the Dock restarts below
        guard self.hidden.contains(element) != hide else { return }
        if hide { self.hide([element]) } else { snapshot.restore(element, store: store); finish([element]) }
    }
    func setAll(hidden hide: Bool) {
        guard hide else { restoreAll(); return }
        chosen = Set(MacElement.allCases); self.hide(chosen)
    }
    func restoreAll(quitting: Bool = false) {
        if !quitting { chosen = [] } // asked for, so it stays that way at the next launch
        let tile = syncDockTile(removing: true)
        let touched = snapshot.restoreAll(store: store)
        if !touched.isEmpty || tile { finish(MacElement.allCases.filter(touched.contains), quitting: quitting, restartDock: tile) }
    }
    /// GNOME's Show Applications, last after the Mac Dock's separator, while the Mac Dock is shown. Put back where it
    /// belongs at each launch; gone when Mnome quits, so the Dock is the person's own again. True when it changed:
    /// the caller restarts the Dock once, with everything else.
    private func syncDockTile(removing: Bool = false) -> Bool {
        let dock = "com.apple.dock" as CFString, key = "persistent-others" as CFString
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Show Applications.app")
        CFPreferencesSynchronize(dock, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) // what the Dock last saved, not our cached copy
        let others = CFPreferencesCopyValue(key, dock, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [[String: Any]] ?? []
        let wanted = !removing && !chosen.contains(.dock) && FileManager.default.fileExists(atPath: helper.path)
        let next = wanted ? MacDockTile.with(others, app: helper) : MacDockTile.without(others)
        guard (next as NSArray) != (others as NSArray) else { return false }
        CFPreferencesSetValue(key, next as CFArray, dock, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesSynchronize(dock, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    private func persist() { if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) } }
    private func finish(_ elements: [MacElement], quitting: Bool = false, restartDock: Bool = false) {
        persist(); hidden = snapshot.hidden
        var processes = Set(elements.compactMap(\.owner))
        if restartDock { processes.insert("Dock") }
        if elements.contains(.desktop) || elements.contains(.missionControl) { processes.insert("WindowManager") } // the widgets; Mission Control lives there on macOS 27
        for name in processes { let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); task.arguments = [name]; try? task.run(); if quitting { task.waitUntilExit() } } // launchd relaunches them with the new prefs
        if elements.contains(.menuBar) { applyMenuBar(quitting: quitting) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.changed?() }
    }
    private func applyMenuBar(quitting: Bool) {
        if #available(macOS 27, *) { // at once and without Automation; not tried on earlier versions
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
            return
        }
        let hide = store.get("NSGlobalDomain", "_HIHideMenuBar") == .bool(true)
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to set autohide menu bar of dock preferences to \(hide)")?.executeAndReturnError(&error)
        if let error {
            if quitting { NSLog("Mnome: could not restore the menu bar while quitting: %@", error); return } // never block quit with an alert
            let alert = NSAlert(); alert.messageText = "Could not change the macOS menu bar"
            alert.informativeText = (error[NSAppleScript.errorMessage] as? String ?? "Unknown error") + "\n\nAllow Mnome to control System Events in System Settings → Privacy & Security → Automation. Use Restore macOS Shell to return to your original settings."
            alert.runModal()
        }
    }
}
