// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
  name: "LDTXAudioKit",
  platforms: [.macOS("27.0")],
  products: [
    .library(
      name: "LDTXAudioKit",
      type: .dynamic,
      targets: ["LDTXAudioKit"]
    ),
    .executable(name: "ldtx-track-record", targets: ["LDTXCmdTrackRecord"])
  ],
  targets: [
    .target(
      name: "LDTXAudioKitCore",
      path: "Sources/LDTXAudioKitCore",
      publicHeadersPath: "include",
      cxxSettings: [
        .headerSearchPath("include"),
        .headerSearchPath("Compositor"),
        .headerSearchPath("Receiver"),
        .unsafeFlags(["-std=c++20"])
      ],
      linkerSettings: [
        .linkedFramework("AudioToolbox"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("CoreFoundation")
      ]
    ),
    .target(
      name: "LDTXAudioKit",
      dependencies: ["LDTXAudioKitCore"],
      path: "Sources/LDTXAudioKit",
      exclude: ["TrackRecorder/README.md"],
      linkerSettings: [
        .linkedFramework("AVFoundation"),
        .linkedFramework("AudioToolbox"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("Foundation")
      ]
    ),
    .executableTarget(
      name: "LDTXCmdTrackRecord",
      dependencies: ["LDTXAudioKit"],
      path: "Sources/LDTXCmdTrackRecord"
    ),
    .testTarget(
      name: "LDTXAudioKitCoreTests",
      dependencies: ["LDTXAudioKitCore"],
      path: "Tests/LDTXAudioKitCoreTests"
    ),
    .testTarget(
      name: "LDTXAudioKitTests",
      dependencies: ["LDTXAudioKit"],
      path: "Tests/LDTXAudioKitTests"
    )
  ]
)
