// swift-tools-version: 6.0

// SPDX-FileCopyrightText: 2025-2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
  name: "ldtx-cli",
  platforms: [.macOS("26.0")],
  products: [
    .executable(name: "ldtx", targets: ["ldtx"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
  ],
  targets: [
    .target(
      name: "LDTXProgram",
      dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
      path: "Sources/LDTXProgram"
    ),
    .target(
      name: "LDTXWorkspace",
      dependencies: [
        "LDTXProgram",
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ],
      path: "Sources/LDTXWorkspace"
    ),
    .target(
      name: "LDTXRecording",
      path: "Sources/LDTXRecording"
    ),
    .target(
      name: "LDTXUtils",
      dependencies: [
        "LDTXRecording",
        "LDTXWorkspace",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources/LDTXUtils"
    ),
    .executableTarget(
      name: "ldtx",
      dependencies: [
        "LDTXUtils",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources",
      sources: ["ldtx-cli/main.swift"]
    ),
    .testTarget(
      name: "LDTXUtilsTests",
      dependencies: ["LDTXUtils"],
      path: "Tests/LDTXUtilsTests"
    ),
  ]
)
