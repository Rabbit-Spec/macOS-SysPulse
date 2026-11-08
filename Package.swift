// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SysPulse",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "SysPulse", targets: ["SysPulse"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SysPulse",
            dependencies: [],
            path: "Sources/SysPulse",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
