// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LumaCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v13)],
    products: [.library(name: "LumaCore", targets: ["LumaCore"])],
    targets: [
        .target(name: "LumaCore", path: "Sources/LumaCore"),
        .testTarget(name: "LumaCoreTests", dependencies: ["LumaCore"], path: "Tests/LumaCoreTests")
    ]
)
