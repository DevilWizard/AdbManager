// swift-tools-version: 6.0
import PackageDescription

/// 界面与 ADB 能力分成独立目标，便于未来增加设备操作而不耦合 SwiftUI。
let package = Package(
    name: "AdbManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AdbManager", targets: ["AdbManager"]),
        .library(name: "AdbManagerCore", targets: ["AdbManagerCore"])
    ],
    targets: [
        .target(name: "AdbManagerCore"),
        .executableTarget(name: "AdbManager", dependencies: ["AdbManagerCore"]),
        .testTarget(
            name: "AdbManagerCoreTests",
            dependencies: ["AdbManagerCore"],
            path: "Tests/AdbManagerCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
