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
      name: "LDTXWorkspaceAppletModel",
      dependencies: [
        "LDTXProgram",
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ],
      path: "Sources/Applets/Workspace/Model"
    ),
    .target(
      name: "LDTXWorkspaceAppletStore",
      dependencies: [
        "LDTXWorkspaceAppletModel",
        "LDTXProgram",
      ],
      path: "Sources/Applets/Workspace/Store",
      sources: [
        "ApplicationSettingsStore.swift",
        "WorkspaceV4IntegrityValidator.swift",
        "WorkspaceLocalStateStorage.swift",
        "WorkspaceV4Package.swift",
        "WorkspaceStore.swift",
      ]
    ),
    .target(
      name: "LDTXWorkspaceAppletService",
      dependencies: [
        "LDTXWorkspaceAppletModel",
        "LDTXWorkspaceAppletStore",
      ],
      path: "Sources/Applets/Workspace/Service",
      sources: [
        "WorkspaceBackupService.swift",
        "WorkspaceResourcePathComponentCodec.swift",
        "WorkspaceV4PackageLock.swift",
        "WorkspaceV4PackageService.swift",
      ]
    ),
    .target(
      name: "LDTXRecording",
      path: "Sources/LDTXRecording"
    ),
    .target(
      name: "LDTXUtils",
      dependencies: [
        "LDTXRecording",
        "LDTXWorkspaceAppletModel",
        "LDTXWorkspaceAppletStore",
        "LDTXWorkspaceAppletService",
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
