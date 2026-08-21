// swift-tools-version: 6.0
import PackageDescription

// The manifest is a Swift program evaluated on the build host, so `#if os(macOS)`
// here decides which targets exist at all. That keeps the SwiftUI/AppKit menu-bar
// app out of the package entirely on Linux, where those frameworks do not exist.
var products: [Product] = [
    .executable(name: "quotabar", targets: ["QuotaBarCLI"])
]

var targets: [Target] = [
    .target(name: "QuotaCore"),
    .target(name: "QuotaTray", dependencies: ["QuotaCore"]),
    .executableTarget(name: "QuotaBarCLI", dependencies: ["QuotaCore"]),
    .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
    .testTarget(name: "QuotaTrayTests", dependencies: ["QuotaTray", "QuotaCore"])
]

// The tray speaks StatusNotifierItem, a freedesktop protocol served over the
// session bus. macOS has no such bus and has the menu-bar app instead, so the
// target does not exist there rather than existing and refusing to run.
#if os(Linux)
products.append(.executable(name: "quotabar-tray", targets: ["QuotaTrayApp"]))
targets.append(.executableTarget(name: "QuotaTrayApp", dependencies: ["QuotaCore", "QuotaTray"]))
#endif

#if os(macOS)
products.append(.executable(name: "QuotaBar", targets: ["QuotaBar"]))
targets.append(.executableTarget(name: "QuotaBar", dependencies: ["QuotaCore"]))
targets.append(.testTarget(name: "QuotaBarTests", dependencies: ["QuotaBar", "QuotaCore"]))
#endif

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
