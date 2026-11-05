// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ICA",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ICAKit", targets: ["ICAKit"]),
        .executable(name: "icactl", targets: ["icactl"]),
        .executable(name: "ICAViewer", targets: ["ICAViewer"]),
    ],
    targets: [
        .target(name: "ICAKit"),
        .executableTarget(name: "icactl", dependencies: ["ICAKit"]),
        .executableTarget(name: "ICAViewer", dependencies: ["ICAKit"]),
        .testTarget(name: "ICAKitTests", dependencies: ["ICAKit"]),
    ],
    swiftLanguageModes: [.v5]
)
