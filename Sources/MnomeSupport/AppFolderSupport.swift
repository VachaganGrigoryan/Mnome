import Foundation

/// A folder in the app grid, as GNOME's: a name and the apps in it, by path.
public struct AppFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: String, name: String, apps: [String]
    public init(id: String, name: String, apps: [String]) { self.id = id; self.name = name; self.apps = apps }
}
/// What the grid shows at its top level.
public enum AppGridEntry: Equatable, Sendable {
    case app(String), folder(AppFolder)
    public var id: String { switch self { case let .app(path): path; case let .folder(f): "folder:\(f.id)" } }
}
public enum AppFolders {
    public static let unnamed = "Unnamed Folder"
    /// Apps and folders together, by name. A folder shows only installed apps, and with fewer than two it is not shown: its app stands alone.
    public static func entries(apps: [(id: String, name: String)], folders: [AppFolder]) -> [AppGridEntry] {
        let installed = Set(apps.map(\.id)), names = Dictionary(apps.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let shown = folders.map { f in AppFolder(id: f.id, name: f.name, apps: f.apps.filter(installed.contains)) }.filter { $0.apps.count >= 2 }
        let inside = Set(shown.flatMap(\.apps))
        let entries = apps.filter { !inside.contains($0.id) }.map { AppGridEntry.app($0.id) } + shown.map(AppGridEntry.folder)
        func name(_ e: AppGridEntry) -> String { switch e { case let .app(path): names[path] ?? path; case let .folder(f): f.name } }
        return entries.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
    /// Dropping one app on another: a new folder with both, taken out of any other folder.
    public static func make(_ a: String, _ b: String, id: String, in folders: [AppFolder]) -> [AppFolder] {
        guard a != b else { return folders }
        return tidy(without([a, b], folders) + [AppFolder(id: id, name: unnamed, apps: [b, a])])
    }
    public static func add(_ app: String, to folder: String, in folders: [AppFolder]) -> [AppFolder] {
        guard folders.contains(where: { $0.id == folder }), !(folders.first { $0.id == folder }!.apps.contains(app)) else { return folders }
        return tidy(without([app], folders).map { $0.id == folder ? AppFolder(id: $0.id, name: $0.name, apps: $0.apps + [app]) : $0 })
    }
    public static func remove(_ app: String, in folders: [AppFolder]) -> [AppFolder] { tidy(without([app], folders)) }
    public static func rename(_ folder: String, to name: String, in folders: [AppFolder]) -> [AppFolder] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return folders.map { $0.id == folder ? AppFolder(id: $0.id, name: name.isEmpty ? $0.name : name, apps: $0.apps) : $0 }
    }
    /// GNOME starts with a Utilities folder; so does the Mac, as a directory.
    public static func seed(apps: [String]) -> [AppFolder] {
        let utilities = apps.filter { $0.contains("/Utilities/") }
        return utilities.count >= 2 ? [AppFolder(id: "utilities", name: "Utilities", apps: utilities)] : []
    }
    private static func without(_ apps: [String], _ folders: [AppFolder]) -> [AppFolder] { folders.map { AppFolder(id: $0.id, name: $0.name, apps: $0.apps.filter { !apps.contains($0) }) } }
    /// A folder down to one app is gone; the app goes back to the grid.
    private static func tidy(_ folders: [AppFolder]) -> [AppFolder] { folders.filter { $0.apps.count >= 2 } }
}
public struct AppFolderStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    /// The seed only the first time: afterwards an empty list is the person's choice.
    public func load(seed: () -> [AppFolder]) -> [AppFolder] {
        if let data = defaults.data(forKey: "appFolders"), let folders = try? JSONDecoder().decode([AppFolder].self, from: data) { return folders }
        let folders = seed(); save(folders); return folders
    }
    public func save(_ folders: [AppFolder]) { if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: "appFolders") } }
}
