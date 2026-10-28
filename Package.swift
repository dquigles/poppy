// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "poppy",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "poppy",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            // Sparkle.framework is copied into Poppy.app/Contents/Frameworks (DESIGN §12.4).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
