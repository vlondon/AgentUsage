// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentAllowance",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentAllowance", targets: ["AgentAllowance"])
    ],
    targets: [
        .target(
            name: "CElectronSafeStorage",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "AgentAllowance",
            dependencies: ["CElectronSafeStorage"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "AgentAllowanceTests",
            dependencies: ["AgentAllowance", "CElectronSafeStorage"]
        )
    ],
    swiftLanguageModes: [.v5]
)
