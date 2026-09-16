// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iFakeGPS-iOS",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "RouteCore", targets: ["RouteCore"])],
    targets: [
        .target(name: "RouteCore"),
        .testTarget(name: "RouteCoreTests", dependencies: ["RouteCore"])
    ]
)
