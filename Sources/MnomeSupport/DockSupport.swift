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
