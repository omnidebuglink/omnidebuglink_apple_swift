// swift-tools-version:5.7
// Floor: Xcode 14 (Swift 5.7). Code uses no 5.8+ features — keep it that way
// unless you re-check: if-let shorthand is the 5.7 syntax boundary.
import PackageDescription

let package = Package(
    name: "omnidebuglink",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "OmniDebugLink", targets: ["OmniDebugLink"])
    ],
    targets: [
        .target(name: "OmniDebugLink", path: "Sources/OmniDebugLink")
    ]
)
