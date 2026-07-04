// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "LDTX",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "LDTXAudioEngine",
            targets: ["LDTXAudioEngine"]
        ),
        .library(
            name: "LDTXAutomation",
            targets: ["LDTXAutomation"]
        ),
        .library(
            name: "LDTXCapture",
            targets: ["LDTXCapture"]
        ),
        .library(
            name: "LDTXDash",
            targets: ["LDTXDash"]
        ),
        .library(
            name: "LDTXMedia",
            targets: ["LDTXMedia"]
        ),
        .library(
            name: "LDTXProgram",
            targets: ["LDTXProgram"]
        ),
        .library(
            name: "LDTXSupport",
            targets: ["LDTXSupport"]
        ),
        .library(
            name: "LDTXYouTube",
            targets: ["LDTXYouTube"]
        ),
        .executable(
            name: "LDTXBrokerService",
            targets: ["LDTXBrokerService"]
        ),
        .executable(
            name: "ldtx",
            targets: ["LDTXCLI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1")
    ],
    targets: [
        .target(
            name: "LDTXAudioEngine",
            publicHeadersPath: "include"
        ),
        .target(
            name: "LDTXAutomation",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            exclude: ["Protos"]
        ),
        .target(
            name: "LDTXSupport"
        ),
        .target(
            name: "LDTXCapture"
        ),
        .target(
            name: "LDTXProgram",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            exclude: ["Protos"]
        ),
        .target(
            name: "LDTXDash",
            dependencies: ["LDTXSupport"]
        ),
        .target(
            name: "LDTXYouTube",
            dependencies: [
                "LDTXDash",
                "LDTXSupport"
            ]
        ),
        .target(
            name: "LDTXMedia",
            dependencies: [
                "LDTXCapture",
                "LDTXDash",
                "LDTXSupport"
            ],
            resources: [
                .process("InputDeviceShaders.metal"),
                .process("VideoCompositorShaders.metal")
            ]
        ),
        .executableTarget(
            name: "LDTXBrokerService",
            dependencies: ["LDTXAutomation"]
        ),
        .executableTarget(
            name: "LDTXCLI",
            dependencies: ["LDTXAutomation"]
        ),
        .testTarget(
            name: "LDTXCoreTests",
            dependencies: [
                "LDTXAutomation",
                "LDTXCapture",
                "LDTXDash",
                "LDTXAudioEngine",
                "LDTXMedia",
                "LDTXProgram",
                "LDTXSupport",
                "LDTXYouTube"
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
