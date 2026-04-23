// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenClawDeployer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "OpenClawDeployer", targets: ["OpenClawDeployer"])
    ],
    targets: [
        .executableTarget(
            name: "OpenClawDeployer",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
