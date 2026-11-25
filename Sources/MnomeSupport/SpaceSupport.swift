import Foundation

/// The Mac's own desktops (Spaces), as SkyLight lists them per display. Mnome's workspaces live in one of them;
/// windows on the others are out of its reach.
public enum MacSpaces {
    /// Displays with more than one desktop, and how many each has. Full-screen apps' Spaces (type 4) do not count.
    public static func extra(from displays: [[String: Any]]) -> [String: Int] {
        displays.reduce(into: [:]) { found, display in
            let desktops = (display["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int ?? 0) == 0 }.count
            if desktops > 1 { found[display["Display Identifier"] as? String ?? "?"] = desktops }
        }
    }
}
