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
      name: "LDTXApp",
      targets: ["LDTXApp"]
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
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
  ],
  targets: [
    .target(
      name: "LDTXAudioEngine",
      publicHeadersPath: "include",
      linkerSettings: [
        .linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio"),
        .linkedFramework("CoreFoundation"), .linkedFramework("CoreMedia"),
      ]
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
      name: "LDTXApp",
      dependencies: [
        "LDTXInternalProtocols",
        "LDTXProgram",
        "LDTXProgramRendering",
        "LDTXProgramRuntime",
        "LDTXVideoComposition",
        "LDTXVideoRendering",
        "LDTXWorkspace",
        "LDTXYouTubeRTMPS",
        "LDTXAudioEngine",
        "LDTXCapture",
        "LDTXDash",
        "LDTXDiagnostics",
        "LDTXMediaTiming",
        "LDTXMP4",
        "LDTXRecording",
        "LDTXTaskQueue",
        "LDTXYouTube",
        "LDTXYouTubeOutputProtocol",
        "LDTXYouTubeAuth",
      ],
      path: "Sources",
      exclude: [
        "LDTXAppEntry",
        "LDTXAudioEngine",
        "LDTXBackgroundSegmentation",
        "LDTXCLI",
        "LDTXCapture",
        "LDTXDash",
        "LDTXDiagnostics",
        "LDTXFontRasterizer",
        "LDTXFullAppFeatures",
        "LDTXInternalProtocols",
        "LDTXMP4",
        "LDTXMediaTiming",
        "LDTXPlayerAppEntry",
        "LDTXProgram",
        "LDTXProgramRendering",
        "LDTXProgramRuntime",
        "LDTXQuickLookPreview",
        "LDTXQuickLookThumbnail",
        "LDTXRecording",
        "LDTXTaskQueue",
        "LDTXVideoComposition",
        "LDTXVideoRendering",
        "LDTXVision",
        "LDTXWorkspace",
        "LDTXYouTube",
        "LDTXYouTubeAuth",
        "LDTXYouTubeOutputProtocol",
        "LDTXYouTubeOutputServiceProcess",
        "LDTXYouTubeRTMPS",
        "LDTXAppUI/Program/Audio/AudioPeakMeter.metal",
        "LDTXAppUI/Workspace/AudioInputSpectrogram.metal",
      ],
      sources: ["LDTXAppCore", "LDTXAppUI", "LDTXAppKitUI", "LDTXRecordPlayerUI"],
      resources: [
        .process("LDTXAppUI/Program/Audio/AudioPeakMeter.metal"),
        .process("LDTXAppUI/Workspace/AudioInputSpectrogram.metal"),
      ],
      swiftSettings: [.interoperabilityMode(.Cxx)]
    ),
    .target(
      name: "LDTXFullAppFeatures",
      dependencies: [
        "LDTXApp",
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
      name: "LDTXAudioEngineEasyTests",
      dependencies: ["LDTXAudioEngine"],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .testTarget(
      name: "LDTXDiagnosticsEasyTests",
      dependencies: ["LDTXDiagnostics"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .testTarget(
      name: "LDTXCLIEasyTests",
      dependencies: ["LDTXHelper"]
    ),
    .testTarget(
      name: "LDTXYouTubeOutputProtocolEasyTests",
      dependencies: ["LDTXYouTubeOutputProtocol"]
    ),
    .testTarget(
      name: "LDTXYouTubeAuthEasyTests",
      dependencies: [
        "LDTXYouTubeAuth",
        .product(name: "AppAuth", package: "AppAuth-iOS"),
      ]
    ),
    .testTarget(
      name: "LDTXBackgroundSegmentationHardTests",
      dependencies: ["LDTXBackgroundSegmentation"]
    ),
    .testTarget(
      name: "LDTXCaptureEasyTests",
      dependencies: ["LDTXCapture"]
    ),
    .testTarget(
      name: "LDTXDashEasyTests",
      dependencies: [
        "LDTXDash",
        "LDTXMP4",
      ]
    ),
    .testTarget(
      name: "LDTXMediaTimingEasyTests",
      dependencies: ["LDTXMediaTiming"]
    ),
    .testTarget(
      name: "LDTXMP4EasyTests",
      dependencies: [
        "LDTXDash",
        "LDTXMediaTiming",
        "LDTXMP4",
      ]
    ),
    .testTarget(
      name: "LDTXRecordingEasyTests",
      dependencies: ["LDTXRecording"]
    ),
    .testTarget(
      name: "LDTXRecordPlayerUIEasyTests",
      dependencies: ["LDTXApp"]
    ),
    .testTarget(
      name: "LDTXTaskQueueEasyTests",
      dependencies: ["LDTXTaskQueue"]
    ),
    .testTarget(
      name: "LDTXProgramEasyTests",
      dependencies: [
        "LDTXProgram",
        "LDTXProgramRendering",
        "LDTXVideoComposition",
      ]
    ),
    .testTarget(
      name: "LDTXProgramHardTests",
      dependencies: [
        "LDTXProgram",
        "LDTXProgramRendering",
        "LDTXVideoComposition",
      ]
    ),
    .testTarget(
      name: "LDTXProgramRuntimeEasyTests",
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
      name: "LDTXProgramRuntimeHardTests",
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
      name: "LDTXIntegrationEasyTests",
      dependencies: [
        "LDTXCapture",
        "LDTXDash",
        "LDTXProgram",
        "LDTXProgramRuntime",
        "LDTXYouTubeOutputProtocol",
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .testTarget(
      name: "LDTXIntegrationHardTests",
      dependencies: [
        "LDTXApp",
        "LDTXCapture",
        "LDTXDiagnostics",
        "LDTXMP4",
        "LDTXProgramRuntime",
        "LDTXRecording",
        "LDTXWorkspace",
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .testTarget(
      name: "LDTXVideoRenderingHardTests",
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
      name: "LDTXVisionEasyTests",
      dependencies: ["LDTXVision", "LDTXWorkspace"]
    ),
    .testTarget(
      name: "LDTXYouTubeEasyTests",
      dependencies: [
        "LDTXDash",
        "LDTXYouTube",
      ]
    ),
    .testTarget(
      name: "LDTXYouTubeRTMPSEasyTests",
      dependencies: ["LDTXYouTubeRTMPS"]
    ),
    .testTarget(
      name: "LDTXWorkspaceEasyTests",
      dependencies: ["LDTXWorkspace"]
    ),
    .testTarget(
      name: "LDTXAppCoreEasyTests",
      dependencies: ["LDTXApp"],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .testTarget(
      name: "LDTXAppCoreHardTests",
      dependencies: ["LDTXApp"],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    .testTarget(
      name: "LDTXFullAppFeaturesEasyTests",
      dependencies: ["LDTXFullAppFeatures", "LDTXApp"],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
  ],
  swiftLanguageModes: [.v6],
  cxxLanguageStandard: .cxx20
)
