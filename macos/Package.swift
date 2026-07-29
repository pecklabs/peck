// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRAgent",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // Pure decision logic with no UI/network deps, split out to be testable.
        .target(
            name: "ReviewLogic",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ReviewLogicTests",
            dependencies: ["ReviewLogic"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "PRAgent",
            dependencies: [
                "ReviewLogic",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .copy("Resources/skills"),
                .copy("Resources/mascots"),
                .copy("Resources/brand")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // Find Sparkle.framework inside the assembled .app bundle.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
