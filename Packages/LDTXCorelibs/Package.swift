// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

// Keep C importer settings identical so Foundation and nanopb modules can be reused.
let nanopbSwiftSettings: [SwiftSetting] = [
  .unsafeFlags([
    "-Xcc", "-DPB_FIELD_32BIT=1", "-Xcc", "-DPB_NO_PACKED_STRUCTS=1",
    "-Xcc", "-DPB_ENABLE_MALLOC=1",
  ])
]

let package = Package(
  name: "LDTXCorelibs",
  platforms: [.macOS("27.0")],
  products: [
    .library(
      name: "LDTXCorelibs", type: .dynamic,
      targets: ["LDTXProtos", "LDTXProgram", "LDTXWorkspaceBundleFormat", "LDTXRecordBundleFormat"]
    )
  ],
  dependencies: [.package(path: "../../Vendors/nanopb")],
  targets: [
    .target(
      name: "LDTXNanopbSupport",
      dependencies: [.product(name: "nanopb", package: "nanopb")],
      path: "LDTXNanopbSupport",
      publicHeadersPath: "include",
      cSettings: [
        .define("PB_FIELD_32BIT", to: "1"),
        .define("PB_NO_PACKED_STRUCTS", to: "1"),
        .define("PB_ENABLE_MALLOC", to: "1"),
      ]
    ),
    .target(
      name: "LDTXNanopb",
      dependencies: ["LDTXNanopbSupport", .product(name: "nanopb", package: "nanopb")],
      path: "LDTXNanopb",
      swiftSettings: nanopbSwiftSettings
    ),
    .target(
      name: "LDTXNanopbMessages",
      dependencies: ["LDTXNanopbSupport", .product(name: "nanopb", package: "nanopb")],
      path: "LDTXProtos/NanopbMessages",
      publicHeadersPath: "include",
      cSettings: [
        .define("PB_FIELD_32BIT", to: "1"),
        .define("PB_NO_PACKED_STRUCTS", to: "1"),
        .define("PB_ENABLE_MALLOC", to: "1"),
      ]
    ),
    .target(
      name: "LDTXProtos",
      dependencies: ["LDTXNanopb", "LDTXNanopbMessages"],
      path: "LDTXProtos",
      exclude: ["NanopbMessages"],
      sources: ["Messages", "Exports.swift"],
      swiftSettings: nanopbSwiftSettings
    ),
    .target(name: "LDTXProgram", path: "LDTXProgram", swiftSettings: nanopbSwiftSettings),
    .target(
      name: "LDTXWorkspaceBundleFormat", dependencies: ["LDTXProtos"],
      path: "LDTXWorkspaceBundleFormat",
      swiftSettings: nanopbSwiftSettings
    ),
    .target(
      name: "LDTXRecordBundleFormat", path: "LDTXRecordBundleFormat",
      swiftSettings: nanopbSwiftSettings
    ),
    .testTarget(
      name: "LDTXCorelibsTests",
      dependencies: [
        "LDTXProtos", "LDTXProgram", "LDTXWorkspaceBundleFormat", "LDTXRecordBundleFormat",
      ],
      path: "Tests",
      swiftSettings: nanopbSwiftSettings
    ),
  ]
)
