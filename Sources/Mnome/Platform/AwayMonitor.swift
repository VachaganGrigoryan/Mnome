import AppKit

/// While the screen is locked or asleep, or another user is in front, macOS reports windows as missing or moved. None of that is true.
@MainActor final class AwayMonitor {
    /// Once macOS has had a moment to put its windows back.
    var returned: () -> Void = {}
    private var reasons: Set<String> = [], back = Date.distantPast, observers: [(NotificationCenter, NSObjectProtocol)] = []
    static var locked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }
    /// As far as we were told. Cheap.
    var isAway: Bool { !reasons.isEmpty }
    /// Just back: what moved meanwhile was macOS's doing. From the moment of return, so no early report slips through.
    var settling: Bool { Date().timeIntervalSince(back) < 3 }
    /// Asks macOS too: an answer may be older than the notification that explains it.
    var mustNotTrust: Bool { isAway || Self.locked || CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter, distributed = DistributedNotificationCenter.default()
        for (reason, center, left, back) in [
            ("lock", distributed as NotificationCenter, NSNotification.Name("com.apple.screenIsLocked"), NSNotification.Name("com.apple.screenIsUnlocked")),
            ("screens", workspace, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            ("sleep", workspace, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            ("user", workspace, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
        ] {
            observers.append((center, center.addObserver(forName: left, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.leave(reason) } }))
            observers.append((center, center.addObserver(forName: back, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.comeBack(reason) } }))
        }
    }
    func stop() { observers.forEach { $0.0.removeObserver($0.1) }; observers = []; reasons = [] }
    func leave(_ reason: String) { reasons.insert(reason) }
    func comeBack(_ reason: String) {
        reasons.remove(reason); back = Date()
        Task { try? await Task.sleep(for: .seconds(1)); if !mustNotTrust { returned() } }
    }
}

/// What the window server itself knows, whatever an app answers.
enum WindowServer {
    /// A window an app closed but kept is still listed.
    static func lists(_ id: UInt64) -> Bool {
        guard id < WindowRegistry.firstMadeUpID else { return false }
        var ids = [UnsafeRawPointer(bitPattern: UInt(id))] // a list of numbers, not of objects
        return CFArrayCreate(nil, &ids, 1, nil).flatMap { CGWindowListCreateDescriptionFromArray($0) as? [Any] }?.isEmpty == false
    }
}
