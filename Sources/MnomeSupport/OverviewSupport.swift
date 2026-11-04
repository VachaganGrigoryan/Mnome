import Foundation
public enum OverviewContent: Equatable {
    case windows, appGrid, searchResults
    public static func content(query: String, windowsMode: Bool) -> OverviewContent {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .searchResults }
        return windowsMode ? .windows : .appGrid
    }
    public static func matches(query: String, title: String, app: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !term.isEmpty && (title.localizedCaseInsensitiveContains(term) || app.localizedCaseInsensitiveContains(term))
    }
}
public enum EscapeAction: Equatable {
    case clearSearch, close
    public static func escape(query: String) -> EscapeAction { query.isEmpty ? .close : .clearSearch }
}
