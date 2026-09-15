// swift-tools-version: 6.0

import PackageDescription

private let upcomingConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "HealthMuleCore",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
        .watchOS("26.0"),
    ],
    products: [
        .library(name: "HealthMuleCore", targets: ["HealthMuleCore"]),
        .library(
            name: "HealthMuleCompanion",
            targets: ["HealthMuleCompanion"]
        ),
        .executable(
            name: "SyncStoreBenchmark",
            targets: ["SyncStoreBenchmark"]
        ),
    ],
    targets: [
        .target(
            name: "HealthMuleCore",
            path: "Sources/HealthMuleCore",
            swiftSettings: upcomingConcurrencySettings
        ),
        .target(
            name: "HealthMuleCompanion",
            path: "HealthMuleShared",
            swiftSettings: upcomingConcurrencySettings
        ),
        .executableTarget(
            name: "SyncStoreBenchmark",
            dependencies: ["HealthMuleCore"],
            path: "Benchmarks/SyncStoreBenchmark",
            swiftSettings: upcomingConcurrencySettings
        ),
        .testTarget(
            name: "HealthMuleCoreTests",
            dependencies: ["HealthMuleCore", "HealthMuleCompanion"],
            path: "Tests",
            sources: ["HealthMuleCoreTests"],
            resources: [.copy("Fixtures")],
            swiftSettings: upcomingConcurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
