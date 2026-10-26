// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "poppy",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "poppy",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Unit tests for the pure logic (`swift test`); the app's behavior is covered by the
        // scripted tests against Poppy Dev (DESIGN §12.2).
        .testTarget(
            name: "poppyTests",
            dependencies: ["poppy"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
