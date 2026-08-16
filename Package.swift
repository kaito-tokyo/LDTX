// swift-tools-version: 6.3

// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
  name: "LDTX",
  platforms: [
    .macOS("26.0")
  ],
  products: [
    .library(
      name: "LDTXAppUI",
      targets: ["LDTXAppUI"]
    ),
    .library(
      name: "LDTXAppCore",
      targets: ["LDTXAppCore"]
    ),
    .library(
      name: "LDTXRecordPlayerUI",
      targets: ["LDTXRecordPlayerUI"]
    ),
    .library(
      name: "LDTXFullAppFeatures",
      targets: ["LDTXFullAppFeatures"]
    ),
    .library(
      name: "LDTXAudioEngine",
      targets: ["LDTXAudioEngine"]
    ),
    .library(
      name: "LDTXBackgroundSegmentation",
      targets: ["LDTXBackgroundSegmentation"]
    ),
    .library(
      name: "LDTXInternalProtocols",
      targets: ["LDTXInternalProtocols"]
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
      name: "LDTXDiagnostics",
      targets: ["LDTXDiagnostics"]
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
      name: "LDTXYouTubeOutputProtocol",
      targets: ["LDTXYouTubeOutputProtocol"]
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
      name: "LDTXRecording",
      type: .static,
      targets: ["LDTXRecording"]
    ),
    .library(
      name: "LDTXTaskQueue",
      targets: ["LDTXTaskQueue"]
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
      name: "LDTXVision",
      targets: ["LDTXVision"]
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
      name: "LDTXYouTubeRTMPS",
      targets: ["LDTXYouTubeRTMPS"]
    ),
    .library(
      name: "LDTXYouTubeAuth",
      targets: ["LDTXYouTubeAuth"]
    ),
    .executable(
      name: "ldtx",
      targets: ["LDTXHelper"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/openid/AppAuth-iOS.git", from: "2.1.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.3"),
    // swift-transformers 1.3.3 still uses String-keyed Jinja objects.
    .package(url: "https://github.com/huggingface/swift-jinja.git", exact: "2.3.6"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
  ],
  targets: [
    .target(
      name: "LDTXAudioEngine",
      publicHeadersPath: "include"
    ),
    .target(
      name: "LDTXBackgroundSegmentation",
      dependencies: ["LDTXInternalProtocols"],
      resources: [
        .process("BackgroundSegmentationShaders.metal")
      ]
    ),
    .target(
      name: "LDTXInternalProtocols"
    ),
    .target(
      name: "LDTXWorkspace",
      dependencies: [
        "LDTXProgram",
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
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
      dependencies: ["LDTXMP4"]
    ),
    .target(
      name: "LDTXYouTube",
      dependencies: ["LDTXDash", "LDTXYouTubeRTMPS"]
    ),
    .target(
      name: "LDTXYouTubeRTMPS"
    ),
    .target(
      name: "LDTXYouTubeAuth",
      dependencies: [
        "LDTXYouTube",
        .product(name: "AppAuth", package: "AppAuth-iOS"),
      ]
    ),
    .target(
      name: "LDTXMediaTiming"
    ),
    .target(name: "LDTXMP4"),
    .target(name: "LDTXRecording"),
    .target(name: "LDTXRecordPlayerUI", dependencies: ["LDTXRecording"]),
    .target(name: "LDTXTaskQueue", dependencies: ["LDTXDiagnostics"]),
    .target(
      name: "LDTXYouTubeOutputProtocol",
      dependencies: [
        .product(name: "SwiftProtobuf", package: "swift-protobuf")
      ],
      exclude: ["Protos"]
    ),
    .target(
      name: "LDTXVideoComposition"
    ),
    .target(
      name: "LDTXFontRasterizer",
      publicHeadersPath: "include"
    ),
    .target(
      name: "LDTXVision",
      dependencies: [
        "LDTXInternalProtocols",
        "LDTXTaskQueue",
        "LDTXWorkspace",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXVLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "Jinja", package: "swift-jinja"),
      ]
    ),
    .target(
      name: "LDTXVideoRendering",
      dependencies: [
        "LDTXVideoComposition"
      ],
      resources: [
        .process("InputDeviceShaders.metal"),
        .process("VideoCompositorShaders.metal"),
      ]
    ),
    .target(
      name: "LDTXProgramRendering",
      dependencies: [
        "LDTXProgram",
        "LDTXVideoComposition",
      ]
    ),
    .target(
      name: "LDTXProgramRuntime",
      dependencies: [
        "LDTXAudioEngine",
        "LDTXCapture",
        "LDTXDash",
        "LDTXFontRasterizer",
        "LDTXInternalProtocols",
        "LDTXMediaTiming",
        "LDTXMP4",
        "LDTXYouTubeRTMPS",
        "LDTXYouTubeOutputProtocol",
        "LDTXProgram",
        "LDTXProgramRendering",
        "LDTXRecording",
        "LDTXTaskQueue",
        "LDTXVideoComposition",
        "LDTXVideoRendering",
      ],
      resources: [
        .process("ClockOverlayShaders.metal"),
        .copy("Resources/NotoSans"),
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .target(
      name: "LDTXDiagnostics",
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    ),
    .target(
      name: "LDTXAppUI",
      dependencies: [
        "LDTXInternalProtocols",
        "LDTXProgram",
        "LDTXProgramRendering",
        "LDTXProgramRuntime",
        "LDTXVideoComposition",
        "LDTXVideoRendering",
        "LDTXWorkspace",
      ],
      path: "Sources/LDTXAppUI",
      resources: [
        .process("Program/Audio/AudioPeakMeter.metal"),
        .process("Workspace/AudioInputSpectrogram.metal"),
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .target(
      name: "LDTXAppCore",
      dependencies: [
        "LDTXAppUI",
        "LDTXAudioEngine",
        "LDTXCapture",
        "LDTXDash",
        "LDTXDiagnostics",
        "LDTXInternalProtocols",
        "LDTXMediaTiming",
        "LDTXMP4",
        "LDTXProgram",
        "LDTXProgramRendering",
        "LDTXProgramRuntime",
        "LDTXRecordPlayerUI",
        "LDTXRecording",
        "LDTXTaskQueue",
        "LDTXVideoComposition",
        "LDTXVideoRendering",
        "LDTXWorkspace",
        "LDTXYouTube",
        "LDTXYouTubeOutputProtocol",
        "LDTXYouTubeAuth",
      ],
      path: "Sources/LDTXAppCore",
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .target(
      name: "LDTXFullAppFeatures",
      dependencies: [
        "LDTXAppCore",
        "LDTXAppUI",
        "LDTXBackgroundSegmentation",
        "LDTXCapture",
        "LDTXInternalProtocols",
        "LDTXProgramRuntime",
        "LDTXTaskQueue",
        "LDTXVision",
        "LDTXWorkspace",
        "LDTXYouTubeAuth",
      ],
      path: "Sources/LDTXFullAppFeatures",
      resources: [
        .process("MediaPipeSelfieSegmenter.mlpackage")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .executableTarget(
      name: "LDTXHelper",
      dependencies: [
        "LDTXDiagnostics",
        "LDTXRecording",
        "LDTXWorkspace",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources/LDTXCLI",
      swiftSettings: [.unsafeFlags(["-parse-as-library"])]
    ),
    .testTarget(
      name: "LDTXAudioEngineTests",
      dependencies: ["LDTXAudioEngine"],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .testTarget(
      name: "LDTXDiagnosticsTests",
      dependencies: ["LDTXDiagnostics"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .testTarget(
      name: "LDTXCLITests",
      dependencies: ["LDTXHelper"]
    ),
    .testTarget(
      name: "LDTXYouTubeOutputProtocolTests",
      dependencies: ["LDTXYouTubeOutputProtocol"]
    ),
    .testTarget(
      name: "LDTXYouTubeAuthTests",
      dependencies: [
        "LDTXYouTubeAuth",
        .product(name: "AppAuth", package: "AppAuth-iOS"),
      ]
    ),
    .testTarget(
      name: "LDTXBackgroundSegmentationTests",
      dependencies: ["LDTXBackgroundSegmentation"]
    ),
    .testTarget(
      name: "LDTXCaptureTests",
      dependencies: ["LDTXCapture"]
    ),
    .testTarget(
      name: "LDTXDashTests",
      dependencies: [
        "LDTXDash",
        "LDTXMP4",
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
      ]
    ),
    .testTarget(
      name: "LDTXRecordingTests",
      dependencies: ["LDTXRecording"]
    ),
    .testTarget(
      name: "LDTXRecordPlayerUITests",
      dependencies: ["LDTXRecordPlayerUI"]
    ),
    .testTarget(
      name: "LDTXTaskQueueTests",
      dependencies: ["LDTXTaskQueue"]
    ),
    .testTarget(
      name: "LDTXProgramTests",
      dependencies: [
        "LDTXProgram",
        "LDTXProgramRendering",
        "LDTXVideoComposition",
      ]
    ),
    .testTarget(
      name: "LDTXProgramRuntimeTests",
      dependencies: [
        "LDTXAudioEngine",
        "LDTXCapture",
        "LDTXDash",
        "LDTXInternalProtocols",
        "LDTXMP4",
        "LDTXProgram",
        "LDTXProgramRuntime",
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .testTarget(
      name: "LDTXVideoRenderingTests",
      dependencies: [
        "LDTXProgramRuntime",
        "LDTXVideoComposition",
        "LDTXVideoRendering",
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .testTarget(
      name: "LDTXVisionTests",
      dependencies: ["LDTXVision", "LDTXWorkspace"]
    ),
    .testTarget(
      name: "LDTXYouTubeTests",
      dependencies: [
        "LDTXDash",
        "LDTXYouTube",
      ]
    ),
    .testTarget(
      name: "LDTXYouTubeRTMPSTests",
      dependencies: ["LDTXYouTubeRTMPS"]
    ),
    .testTarget(
      name: "LDTXWorkspaceTests",
      dependencies: ["LDTXWorkspace"]
    ),
    .testTarget(
      name: "LDTXAppCoreTests",
      dependencies: ["LDTXAppCore", "LDTXAppUI"],
      path: "Tests/LDTXAppTests",
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .testTarget(
      name: "LDTXFullAppFeaturesTests",
      dependencies: ["LDTXFullAppFeatures", "LDTXAppCore"],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
