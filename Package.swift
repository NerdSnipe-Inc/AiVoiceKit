// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AiVoiceKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "AiVoiceKit", targets: ["AiVoiceKit"]),
    ],
    dependencies: [
        // No tagged release includes Cohere CoreML ASR support yet — pinned to an exact
        // commit (not a floating branch) so builds stay reproducible until altic-dev cuts a release.
        .package(url: "https://github.com/altic-dev/FluidAudio.git", revision: "3fd63887eef1dc25edea8263ce4b44aa854d898b"),
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", from: "1.2.0"),
        // Tagged 1.1.0 predates the 4-parameter DynamicNotch<Expanded, CompactLeading,
        // CompactTrailing, CompactBottom> API this package uses — pinned to the exact commit
        // on main (not a floating branch) until a release tag catches up.
        .package(url: "https://github.com/altic-dev/DynamicNotchKit.git", revision: "708f31da5319436c64059ee7ae566953407063d7"),
        .package(url: "https://github.com/mxcl/PromiseKit", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "CoreAudioCaptureSupport",
            path: "Sources/CoreAudioCaptureSupport",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "AiVoiceKit",
            dependencies: [
                "CoreAudioCaptureSupport",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
                "PromiseKit",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .define("AI_VOICE_KIT"),
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .testTarget(
            name: "AiVoiceKitTests",
            dependencies: ["AiVoiceKit"]
        ),
    ]
)
