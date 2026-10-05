// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Monitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Monitor", targets: ["Monitor"]),
    ],
    targets: [
        // System SQLite: part of the macOS SDK; libsqlite3-dev on Linux (CI).
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3",
                       providers: [.apt(["libsqlite3-dev"])]),
        // Everything except the UI: agent client, storage, polling, alert rules.
        // Builds and tests on Linux too, so CI can run it cheaply.
        .target(name: "MonitorCore", dependencies: ["CSQLite"]),
        // The menu bar app (macOS only; the sources are empty elsewhere).
        .executableTarget(name: "Monitor", dependencies: ["MonitorCore"]),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
    ]
)
