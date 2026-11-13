// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ICA",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ICAKit", targets: ["ICAKit"]),
        .executable(name: "icactl", targets: ["icactl"]),
        .executable(name: "ICAViewer", targets: ["ICAViewer"]),
        // Dock identity spike (docs/99 phase 1): template helper app and the host-role CLI.
        .executable(name: "ICAViewerHelper", targets: ["ICAViewerHelper"]),
        .executable(name: "dockspike", targets: ["dockspike"]),
    ],
    targets: [
        .target(name: "ICAKit"),
        .executableTarget(name: "icactl", dependencies: ["ICAKit"]),
        .executableTarget(name: "ICAViewer", dependencies: ["ICAKit"]),
        .testTarget(name: "ICAKitTests", dependencies: ["ICAKit"], resources: [.copy("Fixtures")]),
        // docs/99 spike: bundle relabelling, helper IPC (Mach messages), shared by helper and host.
        .target(name: "CMachBootstrap"),
        .target(name: "AppHostKit", dependencies: ["CMachBootstrap"]),
        .executableTarget(name: "ICAViewerHelper", dependencies: ["AppHostKit"]),
        .executableTarget(name: "dockspike", dependencies: ["AppHostKit"]),
        .testTarget(name: "AppHostKitTests", dependencies: ["AppHostKit"]),
    ],
    swiftLanguageModes: [.v5]
)
