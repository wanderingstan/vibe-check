// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibeCheck",
    platforms: [
        .macOS(.v13) // macOS Ventura - required by LaunchAtLogin
    ],
    products: [
        .executable(
            name: "VibeCheck",
            targets: ["VibeCheck"]
        )
    ],
    dependencies: [
        // GRDB.swift - SQLite toolkit
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),

        // LaunchAtLogin - macOS launch agent helper
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.0.0"),

        // Swift Argument Parser - CLI interface
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "VibeCheck",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/VibeCheck"
        )
        // Tests temporarily disabled - directory not yet created
        // .testTarget(
        //     name: "VibeCheckTests",
        //     dependencies: ["VibeCheck"],
        //     path: "Tests/VibeCheckTests"
        // )
    ]
)
