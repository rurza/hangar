// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hangar",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HangarCore", targets: ["HangarCore"]),
        .library(name: "HangarAppStoreConnect", targets: ["HangarAppStoreConnect"]),
        .library(name: "HangarServer", targets: ["HangarServer"]),
        .library(name: "HangarWorker", targets: ["HangarWorker"]),
        .library(name: "HangarClient", targets: ["HangarClient"]),
        .library(name: "HangarMCP", targets: ["HangarMCP"]),
        .executable(name: "hangar-server", targets: ["hangar-server"]),
        .executable(name: "hangar-worker", targets: ["hangar-worker"]),
        .executable(name: "hangar", targets: ["hangar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.0.0"),
    ],
    targets: [
        .target(name: "HangarCore", dependencies: [
            .product(name: "Dependencies", package: "swift-dependencies"),
            .product(name: "Yams", package: "Yams"),
        ]),
        .target(name: "HangarAppStoreConnect", dependencies: ["HangarCore"]),
        .target(name: "HangarServer", dependencies: [
            "HangarCore", "HangarAppStoreConnect",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            .product(name: "UnixSignals", package: "swift-service-lifecycle"),
        ], resources: [.copy("Web")]),
        .target(name: "HangarWorker", dependencies: [
            "HangarCore", "HangarAppStoreConnect",
            .product(name: "Logging", package: "swift-log"),
        ]),
        .target(name: "HangarClient", dependencies: ["HangarCore"]),
        .target(name: "HangarMCP", dependencies: ["HangarClient", "HangarCore"]),
        .executableTarget(name: "hangar-server", dependencies: [
            "HangarServer", "HangarCore", "HangarAppStoreConnect",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        ]),
        .executableTarget(name: "hangar-worker", dependencies: [
            "HangarWorker", "HangarCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "hangar", dependencies: [
            "HangarClient", "HangarCore", "HangarMCP",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "HangarCoreTests", dependencies: ["HangarCore"]),
        .testTarget(
            name: "HangarAppStoreConnectTests",
            dependencies: ["HangarAppStoreConnect", "HangarCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "HangarServerTests", dependencies: [
            "HangarServer",
            .product(name: "HummingbirdTesting", package: "hummingbird"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        ]),
        .testTarget(name: "HangarWorkerTests", dependencies: ["HangarWorker"], resources: [.copy("Fixtures")]),
        .testTarget(name: "HangarClientTests", dependencies: ["HangarClient", "HangarCore"]),
        .testTarget(name: "HangarMCPTests", dependencies: ["HangarMCP", "HangarClient", "HangarCore"]),
        .testTarget(name: "hangarTests", dependencies: ["hangar", "HangarClient", "HangarCore"]),
    ],
    swiftLanguageModes: [.v6]
)
