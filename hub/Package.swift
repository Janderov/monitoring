// swift-tools-version:5.9
import PackageDescription

// The hub: the same polling, alert rules and backfill as the Mac app
// (MonitorCore), run around the clock on a small Linux server, with
// PostgreSQL instead of SQLite.
let package = Package(
    name: "MonitorHub",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "monitor-hub", targets: ["monitor-hub"]),
    ],
    dependencies: [
        .package(path: "../app"),
        .package(url: "https://github.com/vapor/postgres-nio.git", "1.21.0"..<"2.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", "2.65.0"..<"3.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", "2.27.0"..<"3.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", "1.5.0"..<"2.0.0"),
    ],
    targets: [
        .target(name: "HubCore", dependencies: [
            .product(name: "MonitorCore", package: "app"),
            .product(name: "MonitorReports", package: "app"),
            .product(name: "PostgresNIO", package: "postgres-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "monitor-hub", dependencies: ["HubCore"]),
        .testTarget(name: "HubCoreTests", dependencies: ["HubCore"]),
    ]
)
