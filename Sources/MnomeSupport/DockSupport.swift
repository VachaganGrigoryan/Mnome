import Foundation
import CoreGraphics

public struct Favorite: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public init(id: String, name: String, path: String) { self.id = id; self.name = name; self.path = path }
}
public struct FavoritesStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load(seed: () -> [Favorite]) -> [Favorite] {
        if let data = defaults.data(forKey: "dockFavorites"), let items = try? JSONDecoder().decode([Favorite].self, from: data) { return items }
        let items = seed(); save(items); return items
    }
    public func save(_ items: [Favorite]) { if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: "dockFavorites") } }
    public static func reordered(_ items: [Favorite], moving id: String, before target: String) -> [Favorite] {
        guard id != target, let source = items.first(where: { $0.id == id }), items.contains(where: { $0.id == target }) else { return items }
        var result = items.filter { $0.id != id }; let index = result.firstIndex(where: { $0.id == target })!; result.insert(source, at: index); return result
    }
    public static func movedToEnd(_ items: [Favorite], id: String) -> [Favorite] {
        guard let item = items.first(where: { $0.id == id }) else { return items }
        return items.filter { $0.id != id } + [item]
    }
    public static func resolvedPath(_ favorite: Favorite, lookup: (String) -> String?, exists: (String) -> Bool) -> String? {
        if let path = lookup(favorite.id), exists(path) { return path }
        return exists(favorite.path) ? favorite.path : nil
    }
}
public enum DockGeometry {
    public static func frame(visible: CGRect, count: Int) -> CGRect {
        let width = min(max(80, CGFloat(count) * 64 + 24), max(1, visible.width - 24))
        return CGRect(x: visible.midX - width / 2, y: visible.minY + 8, width: width, height: min(80, max(1, visible.height - 16)))
    }
}
/// Mnome's "Show Applications" tile in the Mac's own Dock: last in the section after the separator (`persistent-others`),
/// where GNOME's dash keeps it; only Trash, which the Dock always ends with, comes after it.
public enum MacDockTile {
    public static let bundle = "dev.mnome.show-applications"
    public static func tile(app: URL) -> [String: Any] {
        ["tile-type": "file-tile", "tile-data": ["bundle-identifier": bundle, "file-label": "Show Applications", "file-data": ["_CFURLString": app.absoluteString, "_CFURLStringType": 15]] as [String: Any]]
    }
    /// By what it opens as well: the Dock rewrites its tiles and does not always keep the bundle identifier.
    public static func isOurs(_ tile: [String: Any]) -> Bool {
        let data = tile["tile-data"] as? [String: Any], url = (data?["file-data"] as? [String: Any])?["_CFURLString"] as? String ?? ""
        return data?["bundle-identifier"] as? String == bundle || url.hasSuffix("/Contents/Library/Show%20Applications.app/") || url.hasSuffix("/Contents/Library/Show%20Applications.app")
    }
    /// Ours at the end, once, pointing at this copy of Mnome; everything else as it was.
    public static func with(_ others: [[String: Any]], app: URL) -> [[String: Any]] { without(others) + [tile(app: app)] }
    public static func without(_ apps: [[String: Any]]) -> [[String: Any]] { apps.filter { !isOurs($0) } }
}
