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
            name: "LDTXBackgroundSegmentation",
            targets: ["LDTXBackgroundSegmentation"]
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
            name: "LDTXMediaTiming",
            targets: ["LDTXMediaTiming"]
        ),
        .library(
            name: "LDTXMP4",
            targets: ["LDTXMP4"]
        ),
        .library(
            name: "LDTXProgram",
            targets: ["LDTXProgram"]
        ),
        .library(
            name: "LDTXProgramRendering",
            targets: ["LDTXProgramRendering"]
        ),
        .library(
            name: "LDTXProgramRuntime",
            targets: ["LDTXProgramRuntime"]
        ),
        .library(
            name: "LDTXSupport",
            targets: ["LDTXSupport"]
        ),
        .library(
            name: "LDTXVideoComposition",
            targets: ["LDTXVideoComposition"]
        ),
        .library(
            name: "LDTXVideoRendering",
            targets: ["LDTXVideoRendering"]
        ),
        .library(
            name: "LDTXWorkspace",
            targets: ["LDTXWorkspace"]
        ),
        .library(
            name: "LDTXYouTube",
            targets: ["LDTXYouTube"]
        ),
        .library(
            name: "LDTXYouTubeAuth",
            targets: ["LDTXYouTubeAuth"]
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
        .package(url: "https://github.com/openid/AppAuth-iOS.git", from: "2.1.0"),
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
            name: "LDTXBackgroundSegmentation"
        ),
        .target(
            name: "LDTXSupport"
        ),
        .target(
            name: "LDTXWorkspace",
            dependencies: [
                "LDTXProgram",
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            exclude: ["Protos"]
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
            name: "LDTXYouTubeAuth",
            dependencies: [
                "LDTXYouTube",
                .product(name: "AppAuth", package: "AppAuth-iOS")
            ]
        ),
        .target(
            name: "LDTXMediaTiming"
        ),
        .target(
            name: "LDTXMP4",
            dependencies: ["LDTXSupport"]
        ),
        .target(
            name: "LDTXVideoComposition"
        ),
        .target(
            name: "LDTXVideoRendering",
            dependencies: [
                "LDTXVideoComposition"
            ],
            resources: [
                .process("InputDeviceShaders.metal"),
                .process("VideoCompositorShaders.metal")
            ]
        ),
        .target(
            name: "LDTXProgramRendering",
            dependencies: [
                "LDTXProgram",
                "LDTXVideoComposition"
            ]
        ),
        .target(
            name: "LDTXProgramRuntime",
            dependencies: [
                "LDTXAudioEngine",
                "LDTXBackgroundSegmentation",
                "LDTXCapture",
                "LDTXDash",
                "LDTXMediaTiming",
                "LDTXMP4",
                "LDTXProgram",
                "LDTXProgramRendering",
                "LDTXSupport",
                "LDTXVideoComposition",
                "LDTXVideoRendering"
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .executableTarget(
            name: "LDTXBrokerService",
            dependencies: ["LDTXAutomation"]
        ),
        .executableTarget(
            name: "LDTXCLI",
            dependencies: [
                "LDTXAutomation",
                "LDTXCapture",
                "LDTXWorkspace"
            ]
        ),
        .testTarget(
            name: "LDTXAudioEngineTests",
            dependencies: ["LDTXAudioEngine"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .testTarget(
            name: "LDTXDashTests",
            dependencies: [
                "LDTXDash",
                "LDTXSupport"
            ]
        ),
        .testTarget(
            name: "LDTXMediaTimingTests",
            dependencies: ["LDTXMediaTiming"]
        ),
        .testTarget(
            name: "LDTXMP4Tests",
            dependencies: [
                "LDTXDash",
                "LDTXMediaTiming",
                "LDTXMP4",
                "LDTXSupport"
            ]
        ),
        .testTarget(
            name: "LDTXProgramTests",
            dependencies: [
                "LDTXProgram",
                "LDTXProgramRendering",
                "LDTXVideoComposition"
            ]
        ),
        .testTarget(
            name: "LDTXProgramRuntimeTests",
            dependencies: [
                "LDTXDash",
                "LDTXMP4",
                "LDTXProgramRuntime",
                "LDTXSupport"
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .testTarget(
            name: "LDTXVideoRenderingTests",
            dependencies: [
                "LDTXVideoComposition",
                "LDTXVideoRendering"
            ]
        ),
        .testTarget(
            name: "LDTXYouTubeTests",
            dependencies: [
                "LDTXSupport",
                "LDTXYouTube"
            ]
        ),
        .testTarget(
            name: "LDTXWorkspaceTests",
            dependencies: ["LDTXWorkspace"]
        )
    ],
    swiftLanguageModes: [.v6]
)
