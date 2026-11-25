import Foundation
import CoreGraphics

/// Where the overview puts things. GNOME's numbers, written from its behaviour and measurements (not its code).
public enum OverviewLayout {
    /// The work area, scaled to fit `available` and centred in it.
    public static func box(workArea: CGSize, in available: CGRect) -> CGRect {
        guard workArea.width > 0, workArea.height > 0, available.width > 0, available.height > 0 else { return available }
        let scale = min(available.width / workArea.width, available.height / workArea.height)
        let size = CGSize(width: workArea.width * scale, height: workArea.height * scale)
        return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width, height: size.height)
    }
    /// Slots for windows in `area` (y down). Rows by window centre, then left to right; small windows are boosted
    /// up to 1.5 times relative to large ones; no window grows past `maxScale` of its real size; rows are added
    /// while they let the windows use more of the area.
    public static func slots(_ windows: [(id: UInt64, rect: CGRect)], in area: CGRect, screenHeight: CGFloat, spacing: CGFloat = 24, maxScale: CGFloat = 0.95) -> [UInt64: CGRect] {
        let items = windows.filter { $0.rect.width > 0 && $0.rect.height > 0 }.sorted { ($0.rect.midY, $0.rect.midX) < ($1.rect.midY, $1.rect.midX) }
        guard !items.isEmpty, area.width > 0, area.height > 0 else { return [:] }
        let boost = items.map { 1.5 - 0.5 * min(1, $0.rect.height / max(1, screenHeight)) }
        let sizes = zip(items, boost).map { CGSize(width: $0.rect.width * $1, height: $0.rect.height * $1) }
        var best: (rows: [[Int]], scale: CGFloat, score: CGFloat)?
        for count in 1...items.count {
            let rows = split(sizes.map(\.width), into: count, spacing: spacing)
            // The gaps stay 24 px whatever the scale.
            let across = rows.map { row in (area.width - spacing * CGFloat(row.count - 1)) / row.reduce(0) { $0 + sizes[$1].width } }.min() ?? 0
            let down = (area.height - spacing * CGFloat(rows.count - 1)) / rows.reduce(0) { total, row in total + (row.map { sizes[$0].height }.max() ?? 0) }
            let scale = min(across, down)
            guard scale > 0 else { break }
            let used = items.indices.reduce(CGFloat(0)) { total, i in let s = min(scale * boost[i], maxScale); return total + items[i].rect.width * s * items[i].rect.height * s }
            let score = used / (area.width * area.height)
            if let best, score <= best.score { break }
            best = (rows, scale, score)
        }
        guard let best else { return [:] }
        let heights = best.rows.map { row in (row.map { sizes[$0].height }.max() ?? 0) * best.scale }
        var y = area.midY - (heights.reduce(0, +) + spacing * CGFloat(best.rows.count - 1)) / 2, result: [UInt64: CGRect] = [:]
        for (row, height) in zip(best.rows, heights) {
            let width = row.reduce(0) { $0 + sizes[$1].width * best.scale } + spacing * CGFloat(row.count - 1)
            var x = area.midX - width / 2
            for i in row {
                let slot = CGSize(width: sizes[i].width * best.scale, height: sizes[i].height * best.scale), s = min(best.scale * boost[i], maxScale)
                let size = CGSize(width: items[i].rect.width * s, height: items[i].rect.height * s)
                result[items[i].id] = CGRect(x: x + (slot.width - size.width) / 2, y: y + (height - size.height) / 2, width: size.width, height: size.height)
                x += slot.width + spacing
            }
            y += height + spacing
        }
        return result
    }
    /// In order, into `count` non-empty rows of about equal width.
    static func split(_ widths: [CGFloat], into count: Int, spacing: CGFloat) -> [[Int]] {
        let target = (widths.reduce(0, +) + spacing * CGFloat(widths.count - count)) / CGFloat(count)
        var rows: [[Int]] = [[]], width: CGFloat = 0
        for (i, w) in widths.enumerated() {
            let left = widths.count - i, rowsLeft = count - rows.count
            if !rows[rows.count - 1].isEmpty, rowsLeft > 0, width + w / 2 > target || left == rowsLeft { rows.append([]); width = 0 }
            rows[rows.count - 1].append(i); width += w + spacing
        }
        return rows
    }
    public static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t, width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}

/// The overview's calculator: + - * / % ^ and brackets on decimal numbers; nil for anything else, never a crash.
public enum Calculator {
    public static func evaluate(_ text: String) -> Double? {
        let chars = Array(text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: ",", with: "."))
        guard chars.contains(where: { "+-*/%^".contains($0) }), chars.contains(where: \.isNumber) else { return nil } // a bare number is not a sum
        var i = 0
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func number() -> Double? {
            let start = i; while let c = peek(), c.isNumber || c == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
        func atom() -> Double? {
            if peek() == "-" { i += 1; return atom().map { -$0 } }
            if peek() == "+" { i += 1; return atom() }
            if peek() == "(" { i += 1; let v = sum(); guard peek() == ")" else { return nil }; i += 1; return v }
            return number()
        }
        func power() -> Double? { guard let base = atom() else { return nil }; if peek() == "^" { i += 1; return power().map { pow(base, $0) } }; return base }
        func product() -> Double? {
            guard var value = power() else { return nil }
            while let op = peek(), "*/%".contains(op) { i += 1; guard let rhs = power() else { return nil }; value = op == "*" ? value * rhs : op == "/" ? value / rhs : value.truncatingRemainder(dividingBy: rhs) }
            return value
        }
        func sum() -> Double? {
            guard var value = product() else { return nil }
            while let op = peek(), op == "+" || op == "-" { i += 1; guard let rhs = product() else { return nil }; value = op == "+" ? value + rhs : value - rhs }
            return value
        }
        guard let value = sum(), i == chars.count, value.isFinite else { return nil }
        return value
    }
    /// As GNOME shows it: no trailing ".0", at most 10 significant digits.
    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.10g", value)
    }
}

/// System Settings panes the overview's search finds, by name or keyword, as GNOME's Settings provider.
public struct SettingsPane: Equatable, Sendable {
    public let name: String, detail: String, pane: String
    let keywords: [String]
    public static let all: [SettingsPane] = [
        .init(name: "Wi-Fi", detail: "Wireless networks", pane: "com.apple.wifi-settings-extension", keywords: ["wifi", "wireless", "network", "internet"]),
        .init(name: "Network", detail: "Ethernet, VPN and firewall", pane: "com.apple.Network-Settings.extension", keywords: ["ethernet", "vpn", "firewall", "proxy", "internet"]),
        .init(name: "Bluetooth", detail: "Wireless devices", pane: "com.apple.BluetoothSettings", keywords: ["devices", "headphones", "keyboard", "mouse"]),
        .init(name: "Sound", detail: "Volume, output and input devices", pane: "com.apple.Sound-Settings.extension", keywords: ["volume", "audio", "speaker", "microphone", "output", "input"]),
        .init(name: "Displays", detail: "Resolution, arrangement and Night Shift", pane: "com.apple.Displays-Settings.extension", keywords: ["screen", "monitor", "resolution", "brightness", "night"]),
        .init(name: "Battery", detail: "Battery status and power saving settings", pane: "com.apple.Battery-Settings.extension", keywords: ["power", "energy", "charging", "low power"]),
        .init(name: "Appearance", detail: "Light and dark style, accent colour", pane: "com.apple.Appearance-Settings.extension", keywords: ["dark", "light", "theme", "accent", "style"]),
        .init(name: "Wallpaper", detail: "Desktop background", pane: "com.apple.Wallpaper-Settings.extension", keywords: ["background", "desktop", "picture"]),
        .init(name: "Desktop & Dock", detail: "Dock, windows and Stage Manager", pane: "com.apple.Desktop-Settings.extension", keywords: ["dock", "windows", "stage manager", "hot corners", "mission control"]),
        .init(name: "Keyboard", detail: "Shortcuts, input sources and dictation", pane: "com.apple.Keyboard-Settings.extension", keywords: ["shortcuts", "input", "layout", "typing", "dictation"]),
        .init(name: "Trackpad", detail: "Gestures and pointer speed", pane: "com.apple.Trackpad-Settings.extension", keywords: ["gestures", "touchpad", "click", "scroll"]),
        .init(name: "Mouse", detail: "Pointer speed and scrolling", pane: "com.apple.Mouse-Settings.extension", keywords: ["pointer", "scroll"]),
        .init(name: "Notifications", detail: "App alerts and banners", pane: "com.apple.Notifications-Settings.extension", keywords: ["alerts", "banners", "badges"]),
        .init(name: "Focus", detail: "Do Not Disturb and focus modes", pane: "com.apple.Focus-Settings.extension", keywords: ["do not disturb", "dnd", "silence"]),
        .init(name: "Privacy & Security", detail: "App permissions and security", pane: "com.apple.settings.PrivacySecurity.extension", keywords: ["permissions", "accessibility", "screen recording", "location", "camera", "microphone", "security"]),
        .init(name: "Lock Screen", detail: "Screen saver and password timing", pane: "com.apple.Lock-Screen-Settings.extension", keywords: ["screen saver", "sleep", "password"]),
        .init(name: "Users & Groups", detail: "Accounts and login items", pane: "com.apple.Users-Groups-Settings.extension", keywords: ["accounts", "user", "login"]),
        .init(name: "Date & Time", detail: "Clock, time zone and date format", pane: "com.apple.Date-Time-Settings.extension", keywords: ["clock", "time zone", "date"]),
        .init(name: "Language & Region", detail: "Language, region and formats", pane: "com.apple.Localization-Settings.extension", keywords: ["language", "region", "locale", "formats"]),
        .init(name: "Accessibility", detail: "Vision, hearing and motor settings", pane: "com.apple.Accessibility-Settings.extension", keywords: ["zoom", "voiceover", "contrast", "motion", "a11y"]),
        .init(name: "Software Update", detail: "Updates for macOS", pane: "com.apple.Software-Update-Settings.extension", keywords: ["update", "upgrade", "macos"]),
        .init(name: "Sharing", detail: "File sharing, screen sharing and AirDrop", pane: "com.apple.Sharing-Settings.extension", keywords: ["airdrop", "file sharing", "remote", "hostname"]),
        .init(name: "Printers & Scanners", detail: "Printers and scanners", pane: "com.apple.Print-Scan-Settings.extension", keywords: ["print", "scan"]),
        .init(name: "Storage", detail: "Disk space", pane: "com.apple.settings.Storage", keywords: ["disk", "space"]),
        .init(name: "General", detail: "About this Mac, software update and storage", pane: "com.apple.systempreferences.GeneralSettings", keywords: ["about", "system", "information"]),
    ]
    /// Every typed word must start a word of the name or a keyword; names first.
    public static func search(_ query: String) -> [SettingsPane] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        func words(_ text: String) -> [String] { text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
        func hits(_ pane: SettingsPane, _ inName: Bool) -> Bool {
            let pool = inName ? words(pane.name) : words(pane.name) + pane.keywords.flatMap(words)
            return terms.allSatisfy { term in pool.contains { $0.hasPrefix(term) } }
        }
        return all.filter { hits($0, true) } + all.filter { !hits($0, true) && hits($0, false) }
    }
}
