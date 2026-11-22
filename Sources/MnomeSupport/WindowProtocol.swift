import CoreGraphics
import Foundation

/// Whole points with a top-left origin, as the Rust core uses them.
public struct WMRect: Codable, Equatable, Hashable, Sendable {
    public var x: Int, y: Int, w: Int, h: Int
    public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    public init(_ r: CGRect) { self.init(x: Int(r.minX.rounded()), y: Int(r.minY.rounded()), w: Int(r.width.rounded()), h: Int(r.height.rounded())) }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    public var json: [String: Any] { ["x": x, "y": y, "w": w, "h": h] }
}
public struct WMDisplay: Equatable, Sendable {
    public let id: UInt64, frame: WMRect, work: WMRect
    public init(id: UInt64, frame: WMRect, work: WMRect) { self.id = id; self.frame = frame; self.work = work }
    public var json: [String: Any] { ["id": id, "frame": frame.json, "work": work.json] }
}
public enum WMSnap: String, Sendable { case left, right, topLeft = "top_left", bottomLeft = "bottom_left", topRight = "top_right", bottomRight = "bottom_right", maximize }
public enum WMDirection: String, Sendable { case left, right, up, down }

/// One request to the core's `wm` operation.
public enum WMEvent: Equatable, Sendable {
    case displays([WMDisplay], main: UInt64)
    case opened(id: UInt64, app: String, rect: WMRect, minimized: Bool, fullscreen: Bool), closed(UInt64), focused(UInt64), moved(UInt64, WMRect)
    case minimized(UInt64, Bool), fullscreen(UInt64, Bool), sticky(UInt64, Bool)
    case activate(UInt64), minimize(UInt64), toggleMaximize(UInt64), restoreOrMinimize(UInt64), snap(UInt64, WMSnap), center(UInt64), resize(UInt64, dw: Int, dh: Int), toDisplay(UInt64, WMDirection)
    case setWorkspace(UInt64), stepWorkspace(Int), toWorkspace(UInt64, UInt64), showDesktop, cycle(backwards: Bool)
    public var json: [String: Any] {
        switch self {
        case let .displays(all, main): ["type": "displays", "displays": all.map(\.json), "main": main]
        case let .opened(id, app, rect, minimized, fullscreen): ["type": "opened", "id": id, "app": app, "rect": rect.json, "minimized": minimized, "fullscreen": fullscreen]
        case let .closed(id): ["type": "closed", "id": id]
        case let .focused(id): ["type": "focused", "id": id]
        case let .moved(id, rect): ["type": "moved", "id": id, "rect": rect.json]
        case let .minimized(id, on): ["type": "minimized", "id": id, "on": on]
        case let .fullscreen(id, on): ["type": "fullscreen", "id": id, "on": on]
        case let .sticky(id, on): ["type": "sticky", "id": id, "on": on]
        case let .activate(id): ["type": "activate", "id": id]
        case let .minimize(id): ["type": "minimize", "id": id]
        case let .toggleMaximize(id): ["type": "toggle_maximize", "id": id]
        case let .restoreOrMinimize(id): ["type": "restore_or_minimize", "id": id]
        case let .snap(id, to): ["type": "snap", "id": id, "to": to.rawValue]
        case let .center(id): ["type": "center", "id": id]
        case let .resize(id, dw, dh): ["type": "resize", "id": id, "dw": dw, "dh": dh]
        case let .toDisplay(id, direction): ["type": "to_display", "id": id, "direction": direction.rawValue]
        case let .setWorkspace(ws): ["type": "set_workspace", "workspace": ws]
        case let .stepWorkspace(delta): ["type": "step_workspace", "delta": delta]
        case let .toWorkspace(id, ws): ["type": "to_workspace", "id": id, "workspace": ws]
        case .showDesktop: ["type": "show_desktop"]
        case let .cycle(backwards): ["type": "cycle", "backwards": backwards]
        }
    }
}
public enum WMOp: Equatable, Sendable {
    case unminimize(UInt64), unpark(UInt64, WMRect), place(UInt64, WMRect), focus(UInt64), park(UInt64), minimize(UInt64)
    public init?(json: [String: Any]) {
        guard let name = json["op"] as? String, let id = (json["window"] as? NSNumber)?.uint64Value else { return nil }
        let rect = (json["rect"] as? [String: Int]).flatMap { r in r["x"].flatMap { x in r["y"].flatMap { y in r["w"].flatMap { w in r["h"].map { WMRect(x: x, y: y, w: w, h: $0) } } } } }
        switch (name, rect) {
        case ("unminimize", _): self = .unminimize(id)
        case let ("unpark", rect?): self = .unpark(id, rect)
        case let ("place", rect?): self = .place(id, rect)
        case ("focus", _): self = .focus(id)
        case ("park", _): self = .park(id)
        case ("minimize", _): self = .minimize(id)
        default: return nil
        }
    }
}
/// The part of the core's state the shell shows.
public struct WMState: Decodable, Equatable, Sendable {
    public struct Window: Decodable, Equatable, Sendable { public let id: UInt64, app: String, display: UInt64, workspace: UInt64, minimized: Bool, fullscreen: Bool, sticky: Bool, rect: WMRect }
    public let windows: [Window], workspaces: [UInt64], current: UInt64, focus: UInt64?, main: UInt64
    public func window(_ id: UInt64) -> Window? { windows.first { $0.id == id } }
    public init(json: Any) throws { self = try JSONDecoder().decode(WMState.self, from: JSONSerialization.data(withJSONObject: json)) }
}
