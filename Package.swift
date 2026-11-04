// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Mnome", platforms: [.macOS(.v15)], targets: [
 .systemLibrary(name: "CMnome", path: "Sources/CMnome"),
 .target(name: "MnomeSupport"),
 .testTarget(name: "MnomeSupportTests", dependencies: ["MnomeSupport"]),
 .executableTarget(name: "Mnome", dependencies: ["CMnome", "MnomeSupport"], resources: [.process("Resources")], linkerSettings: [.unsafeFlags(["-Lcore/target/release", "-lmnome_core"])])
], swiftLanguageModes: [.v5])
