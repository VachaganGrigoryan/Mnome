import Foundation
public struct ShortcutChoice: Equatable {
    public let title: String
    public let mask: Int // Carbon modifier mask (control 4096, option 2048, shift 512, command 256)
    public static let all = [
        ShortcutChoice(title: "Control–Option–Space", mask: 4096 | 2048),
        ShortcutChoice(title: "Control–Shift–Space", mask: 4096 | 512),
        ShortcutChoice(title: "Command–Shift–Space", mask: 256 | 512),
    ]
    public static func choice(forMask mask: Int) -> ShortcutChoice { all.first { $0.mask == mask } ?? all[0] }
}
