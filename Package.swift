// swift-tools-version: 6.2
import PackageDescription

// maclang — 100% Pure Swift single binary. No third-party dependencies.
// Release builds are optimized for size (same rationale as mac-local-vision).
let releaseSizeOpt: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]

let package = Package(
    name: "mac-local-language",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "maclang", targets: ["maclang"]),
    ],
    targets: [
        .executableTarget(
            name: "maclang",
            dependencies: ["LangCore", "LangEngine"],
            swiftSettings: releaseSizeOpt
        ),
        // Pure logic only (Foundation). No network or framework calls.
        .target(name: "LangCore", swiftSettings: releaseSizeOpt),
        // Translation / NaturalLanguage bound code.
        .target(name: "LangEngine", dependencies: ["LangCore"], swiftSettings: releaseSizeOpt),
        .testTarget(name: "LangCoreTests", dependencies: ["LangCore"]),
        .testTarget(name: "LangEngineTests", dependencies: ["LangEngine", "LangCore"]),
    ]
)
