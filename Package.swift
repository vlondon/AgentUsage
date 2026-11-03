// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentAllowance",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentAllowance", targets: ["AgentAllowance"]),
        .executable(name: "allowance", targets: ["allowance"]),
        .library(name: "AgentAllowanceCore", targets: ["AgentAllowanceCore"])
    ],
    targets: [
        .target(
            name: "CElectronSafeStorage",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AgentAllowanceCore",
            dependencies: ["CElectronSafeStorage"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "AgentAllowance",
            dependencies: ["AgentAllowanceCore"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "allowance",
            dependencies: ["AgentAllowanceCore"]
        ),
        .testTarget(
            name: "AgentAllowanceTests",
            dependencies: ["AgentAllowance", "AgentAllowanceCore", "CElectronSafeStorage"]
        )
    ],
    swiftLanguageModes: [.v5]
)
