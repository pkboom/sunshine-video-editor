// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sunshine",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Sunshine", targets: ["Sunshine"]),
    ],
    targets: [
        .target(name: "SunshineCore"),
        .executableTarget(name: "Sunshine", dependencies: ["SunshineCore"]),
        .testTarget(name: "SunshineCoreTests", dependencies: ["SunshineCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SunshineIntegrationTests", dependencies: ["SunshineCore", "Sunshine"],
                    exclude: ["Generated"]),
    ]
)
