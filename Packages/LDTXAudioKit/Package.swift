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
    )
  ],
  targets: [
    .target(
      name: "LDTXAudioKit",
      path: "Sources/LDTXAudioKit",
      publicHeadersPath: "include",
      cxxSettings: [
        .headerSearchPath("include"),
        .headerSearchPath("Compositor/Internal"),
        .unsafeFlags(["-std=c++20"])
      ],
      linkerSettings: [
        .linkedFramework("AudioToolbox"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("CoreFoundation")
      ]
    ),
    .testTarget(
      name: "LDTXAudioKitTests",
      dependencies: ["LDTXAudioKit"],
      path: "Tests/LDTXAudioKitTests"
    )
  ]
)
