// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MurkKit",
    platforms: [.iOS("18.0")],
    products: [.library(name: "MurkKit", targets: ["MurkKit"])],
    targets: [
        .target(name: "MurkKit"),
        .testTarget(name: "MurkKitTests", dependencies: ["MurkKit"])
    ]
)
