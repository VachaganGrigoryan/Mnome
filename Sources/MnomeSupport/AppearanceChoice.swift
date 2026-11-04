import Foundation
public enum AppearanceChoice: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"
    public static func saved(_ value: String?) -> AppearanceChoice { value.flatMap(Self.init(rawValue:)) ?? .system }
}
