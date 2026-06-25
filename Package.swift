// swift-tools-version: 6.0
import PackageDescription

// BigCSVKit compiles the pure core logic that lives in `bigcsv/Core/`.
// Those same files are ALSO compiled into the app target (via the Xcode
// synchronized folder), so this package exists purely to run the core's
// unit tests fast with `swift test` — no Xcode/destination needed.
//
// IMPORTANT: the core compiles in two isolation contexts (app = MainActor
// default, package = nonisolated default), so every core type must declare
// its isolation explicitly. Keep both `xcodebuild build` and `swift test` green.
let package = Package(
    name: "BigCSVKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BigCSVKit", targets: ["BigCSVKit"]),
    ],
    targets: [
        .target(
            name: "BigCSVKit",
            path: "bigcsv/Core"
        ),
        .testTarget(
            name: "BigCSVKitTests",
            dependencies: ["BigCSVKit"],
            path: "Tests/BigCSVKitTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
