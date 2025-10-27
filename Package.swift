// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EnergeticWorkspace",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SharedInfrastructure", targets: ["SharedInfrastructure"]),
        .library(name: "CapsuleCore", targets: ["CapsuleCore"]),
        .library(name: "EnergeticCore", targets: ["EnergeticCore"]),
        .library(name: "CapsuleUI", targets: ["CapsuleUI"]),
        .library(name: "EnergeticUI", targets: ["EnergeticUI"]),
        .executable(name: "capsule-cli", targets: ["CapsuleCLI"]),
        .executable(name: "energetic-cli", targets: ["EnergeticCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")
    ],
    targets: [
        .target(
            name: "SharedInfrastructure",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/SharedInfrastructure"
        ),
        .target(
            name: "CapsuleCore",
            dependencies: ["SharedInfrastructure"],
            path: "Sources/CapsuleCore"
        ),
        .target(
            name: "EnergeticCore",
            dependencies: ["SharedInfrastructure"],
            path: "Sources/EnergeticCore"
        ),
        .target(
            name: "CapsuleUI",
            dependencies: ["SharedInfrastructure", "CapsuleCore"],
            path: "Sources/CapsuleUI"
        ),
        .target(
            name: "EnergeticUI",
            dependencies: ["SharedInfrastructure", "EnergeticCore"],
            path: "Sources/EnergeticUI"
        ),
        .executableTarget(
            name: "CapsuleCLI",
            dependencies: ["SharedInfrastructure", "CapsuleCore"],
            path: "Sources/CapsuleCLI"
        ),
        .executableTarget(
            name: "EnergeticCLI",
            dependencies: ["SharedInfrastructure", "EnergeticCore"],
            path: "Sources/EnergeticCLI"
        ),
        .testTarget(
            name: "SharedInfrastructureTests",
            dependencies: ["SharedInfrastructure"],
            path: "Tests/SharedInfrastructureTests"
        ),
        .testTarget(
            name: "CapsuleCoreTests",
            dependencies: ["CapsuleCore", "SharedInfrastructure"],
            path: "Tests/CapsuleCoreTests"
        ),
        .testTarget(
            name: "EnergeticCoreTests",
            dependencies: ["EnergeticCore"],
            path: "Tests/EnergeticCoreTests"
        )
    ]
)
