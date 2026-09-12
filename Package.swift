// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SourceDesk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SourceDesk", targets: ["SourceDesk"]),
        .library(name: "SourceDeskCore", targets: ["SourceDeskCore"]),
    ],
    dependencies: [],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "SourceDeskCore",
            dependencies: ["CZlib"],
            path: "Sources/SourceDeskCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("PDFKit"),
            ]
        ),
        .executableTarget(
            name: "SourceDesk",
            dependencies: ["SourceDeskCore"],
            path: "Sources/SourceDesk",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Security"),
            ]
        ),
        // Headless verification harness. SwiftPM's XCTest/swift-testing are not
        // usable with the Command Line Tools alone, so the test suites live in a
        // normal executable target that runs every suite and exits non-zero on
        // failure (see `scripts/test.sh`).
        .executableTarget(
            name: "SourceDeskHarness",
            dependencies: ["SourceDeskCore"],
            path: "Tests/Harness"
        ),
    ]
)
