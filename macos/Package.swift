// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentPager",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AgentGridShared", targets: ["AgentGridShared"]),
        .library(name: "AgentGridCore", targets: ["AgentGridCore"]),
        .executable(name: "AgentGridBridge", targets: ["AgentGridBridge"]),
        .executable(name: "AgentGridHooks", targets: ["AgentGridHooks"]),
    ],
    targets: [
        // 协议、领域模型与手机会话：只依赖 Foundation/CryptoKit/Network，macOS 与 iOS 共用。
        .target(name: "AgentGridShared"),
        .target(
            name: "AgentGridCore",
            dependencies: ["AgentGridShared"]
        ),
        .executableTarget(
            name: "AgentGridBridge",
            dependencies: ["AgentGridCore"]
        ),
        .executableTarget(
            name: "AgentGridHooks",
            dependencies: ["AgentGridCore"]
        ),
        .testTarget(
            name: "AgentGridSharedTests",
            dependencies: ["AgentGridShared"]
        ),
        .testTarget(
            name: "AgentGridCoreTests",
            dependencies: ["AgentGridCore"]
        ),
        .testTarget(
            name: "AgentGridBridgeTests",
            dependencies: ["AgentGridBridge", "AgentGridCore"]
        ),
    ]
)
