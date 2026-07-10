// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Wuyan",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Wuyan", targets: ["Wuyan"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Wuyan",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Wuyan",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Quartz")
            ]
        ),
        .testTarget(
            name: "WuyanTests",
            dependencies: ["Wuyan"],
            path: "WuyanTests"
        )
    ]
)
