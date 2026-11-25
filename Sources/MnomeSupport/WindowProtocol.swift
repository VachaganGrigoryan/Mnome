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
/// What the core reports as `placement`: tiles and maximized windows come back to their own size when dragged.
public enum WMPlacement: Equatable, Sendable, Decodable {
    case free, maximized, tiled
    public init(from decoder: Decoder) throws { self = (try? decoder.singleValueContainer().decode(String.self)).map { $0 == "maximized" ? .maximized : .free } ?? .tiled }
}
/// A boundary two tiles share, as the core's `wm_hit` reports it.
public struct WMBorder: Equatable, Sendable {
    public let workspace: UInt64, display: UInt64, column: Int?, boundary: Int
    /// Between columns, so it moves sideways.
    public var vertical: Bool { column == nil }
    public init(workspace: UInt64, display: UInt64, column: Int?, boundary: Int) { self.workspace = workspace; self.display = display; self.column = column; self.boundary = boundary }
    public init?(json: Any?) {
        guard let o = json as? [String: Any], let key = o["key"] as? [String: Any], let w = (key["workspace"] as? NSNumber)?.uint64Value, let d = (key["display"] as? NSNumber)?.uint64Value, let border = o["border"] as? [String: Any] else { return nil }
        if let c = border["column"] as? [String: Any], let b = (c["boundary"] as? NSNumber)?.intValue { self.init(workspace: w, display: d, column: nil, boundary: b) }
        else if let r = border["row"] as? [String: Any], let column = (r["column"] as? NSNumber)?.intValue, let b = (r["boundary"] as? NSNumber)?.intValue { self.init(workspace: w, display: d, column: column, boundary: b) }
        else { return nil }
    }
    var keyJSON: [String: Any] { ["workspace": workspace, "display": display] }
    var borderJSON: [String: Any] { column.map { ["row": ["column": $0, "boundary": boundary]] } ?? ["column": ["boundary": boundary]] }
}
/// The core's `wm_hit` answer: the snap zone and the tile border under the pointer.
public struct WMHit: Equatable, Sendable {
    public let snap: WMSnap?, border: WMBorder?
    public init(json: [String: Any]) { snap = (json["snap"] as? String).flatMap(WMSnap.init(rawValue:)); border = WMBorder(json: json["border"]) }
}
/// Where a drag into a zone will put the window, for the preview. As the core's `snap` into an empty group.
public enum TilePreview {
    public static func rect(for snap: WMSnap, work: WMRect) -> WMRect {
        let half = WMRect(x: work.x, y: work.y, w: work.w / 2, h: work.h), right = WMRect(x: work.x + work.w / 2, y: work.y, w: work.w - work.w / 2, h: work.h)
        func top(_ r: WMRect) -> WMRect { WMRect(x: r.x, y: r.y, w: r.w, h: r.h / 2) }
        func bottom(_ r: WMRect) -> WMRect { WMRect(x: r.x, y: r.y + r.h / 2, w: r.w, h: r.h - r.h / 2) }
        switch snap {
        case .left: return half
        case .right: return right
        case .topLeft: return top(half)
        case .bottomLeft: return bottom(half)
        case .topRight: return top(right)
        case .bottomRight: return bottom(right)
        case .maximize: return work
        }
    }
}

/// One request to the core's `wm` operation.
public enum WMEvent: Equatable, Sendable {
    case displays([WMDisplay], main: UInt64)
    case opened(id: UInt64, app: String, rect: WMRect, minimized: Bool, fullscreen: Bool), closed(UInt64), focused(UInt64), moved(UInt64, WMRect, bySystem: Bool = false)
    case minimized(UInt64, Bool), hidden(UInt64, Bool), fullscreen(UInt64, Bool), sticky(UInt64, Bool), workspacesOn(Bool)
    case activate(UInt64), minimize(UInt64), toggleMaximize(UInt64), restore(UInt64), snap(UInt64, WMSnap), center(UInt64), resize(UInt64, dw: Int, dh: Int), toDisplay(UInt64, WMDirection)
    case setWorkspace(UInt64), stepWorkspace(Int), toWorkspace(UInt64, UInt64), carryWindow(UInt64, Int), showDesktop, cycle(backwards: Bool)
    /// `header`: how far below the window's top the pointer holds it.
    case dragAway(UInt64, x: Int, y: Int, header: Int), dragBorder(WMBorder, coordinate: Int)
    public var json: [String: Any] {
        switch self {
        case let .displays(all, main): ["type": "displays", "displays": all.map(\.json), "main": main]
        case let .opened(id, app, rect, minimized, fullscreen): ["type": "opened", "id": id, "app": app, "rect": rect.json, "minimized": minimized, "fullscreen": fullscreen]
        case let .closed(id): ["type": "closed", "id": id]
        case let .focused(id): ["type": "focused", "id": id]
        case let .moved(id, rect, bySystem): ["type": "moved", "id": id, "rect": rect.json, "by_system": bySystem]
        case let .minimized(id, on): ["type": "minimized", "id": id, "on": on]
        case let .hidden(id, on): ["type": "hidden", "id": id, "on": on]
        case let .workspacesOn(on): ["type": "workspaces_on", "on": on]
        case let .fullscreen(id, on): ["type": "fullscreen", "id": id, "on": on]
        case let .sticky(id, on): ["type": "sticky", "id": id, "on": on]
        case let .activate(id): ["type": "activate", "id": id]
        case let .minimize(id): ["type": "minimize", "id": id]
        case let .toggleMaximize(id): ["type": "toggle_maximize", "id": id]
        case let .restore(id): ["type": "restore", "id": id]
        case let .snap(id, to): ["type": "snap", "id": id, "to": to.rawValue]
        case let .center(id): ["type": "center", "id": id]
        case let .resize(id, dw, dh): ["type": "resize", "id": id, "dw": dw, "dh": dh]
        case let .toDisplay(id, direction): ["type": "to_display", "id": id, "direction": direction.rawValue]
        case let .setWorkspace(ws): ["type": "set_workspace", "workspace": ws]
        case let .stepWorkspace(delta): ["type": "step_workspace", "delta": delta]
        case let .toWorkspace(id, ws): ["type": "to_workspace", "id": id, "workspace": ws]
        case let .carryWindow(id, delta): ["type": "carry_window", "id": id, "delta": delta]
        case .showDesktop: ["type": "show_desktop"]
        case let .cycle(backwards): ["type": "cycle", "backwards": backwards]
        case let .dragAway(id, x, y, header): ["type": "drag_away", "id": id, "x": x, "y": y, "header": header]
        case let .dragBorder(border, coordinate): ["type": "drag_border", "key": border.keyJSON, "border": border.borderJSON, "coordinate": coordinate]
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
    public struct Window: Decodable, Equatable, Sendable { public let id: UInt64, app: String, display: UInt64, workspace: UInt64, minimized: Bool, hidden: Bool, fullscreen: Bool, sticky: Bool, rect: WMRect; public let placement: WMPlacement? }
    public let windows: [Window], workspaces: [UInt64], current: UInt64, focus: UInt64?, main: UInt64, mru: [UInt64], workspacesOn: Bool
    private enum CodingKeys: String, CodingKey { case windows, workspaces, current, focus, main, mru, workspacesOn = "workspaces_on" }
    public func window(_ id: UInt64) -> Window? { windows.first { $0.id == id } }
    /// Waiting in the corner: as the core's `presence`.
    public func isParked(_ id: UInt64) -> Bool { window(id).map { workspacesOn && !$0.minimized && !$0.hidden && !$0.fullscreen && !$0.sticky && $0.display == main && $0.workspace != current } ?? false }
    public func isShown(_ id: UInt64) -> Bool { window(id).map { !$0.minimized && !$0.hidden && !isParked(id) } ?? false }
    public init(json: Any) throws { self = try JSONDecoder().decode(WMState.self, from: JSONSerialization.data(withJSONObject: json)) }
}
