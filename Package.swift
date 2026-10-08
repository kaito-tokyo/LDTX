// swift-tools-version: 6.0

// SPDX-FileCopyrightText: 2025-2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

var targets: [Target] = [
  .target(name: "LDTXRecordBundleFormat", path: "Sources/Corelibs/LDTXRecordBundleFormat"),
  .target(
    name: "LDTXProgram",
    dependencies: [
      "LDTXProtos",
      .product(name: "SwiftProtobuf", package: "swift-protobuf"),
    ],
    path: "Sources/Corelibs/LDTXProgram"
  ),
  .target(
    name: "LDTXProtos",
    dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
    path: "Sources/Corelibs/LDTXProtos"
  ),
  .target(
    name: "LDTXWorkspaceBundleFormat",
    dependencies: [
      "LDTXProtos",
      .product(name: "SwiftProtobuf", package: "swift-protobuf"),
    ],
    path: "Sources/Corelibs/LDTXWorkspaceBundleFormat"
  ),
  .testTarget(
    name: "LDTXCorelibsTests",
    dependencies: [
      "LDTXProtos", "LDTXProgram", "LDTXWorkspaceBundleFormat", "LDTXRecordBundleFormat",
    ],
    path: "Tests/Corelibs"
  ),
]

var products: [Product] = []
var dependencies: [Package.Dependency] = [
  .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
  .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
]

#if os(macOS)
  products.append(.executable(name: "ldtx", targets: ["ldtx"]))
  targets += [
    .target(
      name: "LDTXProtosMacOSExtra",
      dependencies: ["LDTXProtos"],
      path: "Sources/LDTXProtosMacOSExtra"
    ),
    .testTarget(
      name: "LDTXProtosMacOSExtraTests",
      dependencies: ["LDTXProtos", "LDTXProtosMacOSExtra"],
      path: "Tests/LDTXProtosMacOSExtraTests"
    ),
    .target(
      name: "LDTXWorkspaceAppletModel",
      dependencies: [
        "LDTXProtos",
        "LDTXProgram",
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ],
      path: "Sources/Applets/Workspace/Model"
    ),
    .target(
      name: "LDTXWorkspaceAppletStore",
      dependencies: [
        "LDTXWorkspaceAppletModel",
        "LDTXWorkspaceBundleFormat",
        "LDTXProtos",
        "LDTXProgram",
      ],
      path: "Sources/Applets/Workspace/Store",
      sources: ["ApplicationSettingsStore.swift"]
    ),
    .target(
      name: "LDTXWorkspaceAppletService",
      dependencies: [
        "LDTXWorkspaceAppletModel",
        "LDTXWorkspaceAppletStore",
        "LDTXWorkspaceBundleFormat",
        "LDTXProtos",
      ],
      path: "Sources/Applets/Workspace/Service",
      sources: ["WorkspaceResourcePathComponentCodec.swift"]
    ),
    .target(
      name: "LDTXRecording",
      dependencies: ["LDTXRecordBundleFormat"],
      path: "Sources/LDTXRecording"
    ),
    .target(
      name: "LDTXUtils",
      dependencies: [
        "LDTXRecording",
        "LDTXRecordBundleFormat",
        "LDTXWorkspaceBundleFormat",
        "LDTXProtos",
        "LDTXWorkspaceAppletModel",
        "LDTXWorkspaceAppletStore",
        "LDTXWorkspaceAppletService",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources/LDTXUtils",
      exclude: ["ProgramRenderCommand.swift"],
      sources: ["Commands.swift"]
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
      dependencies: [
        "LDTXUtils",
        "LDTXWorkspaceBundleFormat",
        "LDTXProtos",
        "LDTXWorkspaceAppletModel",
        "LDTXWorkspaceAppletStore",
      ],
      path: "Tests/LDTXUtilsTests"
    ),
  ]
#endif

let package = Package(
  name: "ldtx-cli",
  platforms: [.macOS("26.0")],
  products: products,
  dependencies: dependencies,
  targets: targets
)
