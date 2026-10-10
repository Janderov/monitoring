// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Monitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Monitor", targets: ["Monitor"]),
        // The core alone, for the hub (hub/) that runs the same rounds on a server.
        .library(name: "MonitorCore", targets: ["MonitorCore"]),
        // Client reports, for the hub's monthly job and the /r/<token> page.
        .library(name: "MonitorReports", targets: ["MonitorReports"]),
    ],
    dependencies: [
        // CryptoKit's API on Linux, so the core (sealed passwords) tests in CI.
        // On macOS the app uses CryptoKit itself.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        // System SQLite: part of the macOS SDK; libsqlite3-dev on Linux (CI).
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3",
                       providers: [.apt(["libsqlite3-dev"])]),
        // Everything except the UI: agent client, storage, polling, alert rules.
        // Builds and tests on Linux too, so CI can run it cheaply.
        .target(name: "MonitorCore", dependencies: [
            "CSQLite",
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]),
        // The menu bar app (macOS only; the sources are empty elsewhere).
        // SwiftUI views and the observable app model (macOS only; empty on Linux).
        .target(name: "MonitorUI", dependencies: ["MonitorCore", "MonitorReports"]),
        // Monthly client reports: builds the snapshot from the hub's database
        // rows, renders the page and PDF source, link tokens. No UI, no driver.
        .target(name: "MonitorReports", dependencies: ["MonitorCore"]),
        .executableTarget(name: "Monitor", dependencies: ["MonitorCore", "MonitorUI"]),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
        .testTarget(name: "MonitorReportsTests", dependencies: ["MonitorReports"]),
    ]
)
