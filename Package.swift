// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "catdex-status",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CatdexCore", targets: ["CatdexCore"]),
        .executable(name: "catdex", targets: ["catdex"]),
        .executable(name: "CatdexMenu", targets: ["CatdexMenu"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(
            name: "CatdexCore", dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "catdex",
            dependencies: ["CatdexCore"]
        ),
        .executableTarget(
            name: "CatdexMenu",
            dependencies: ["CatdexCore"]
        ),
        .testTarget(
            name: "CatdexCoreTests",
            dependencies: ["CatdexCore"]
        ),
    ]
)
