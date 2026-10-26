// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

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
      swiftSettings: [
        .unsafeFlags([
          "-Xcc", "-DPB_FIELD_32BIT=1", "-Xcc", "-DPB_NO_PACKED_STRUCTS=1",
          "-Xcc", "-DPB_ENABLE_MALLOC=1",
        ])
      ]
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
      swiftSettings: [
        .unsafeFlags([
          "-Xcc", "-DPB_FIELD_32BIT=1",
          "-Xcc", "-DPB_NO_PACKED_STRUCTS=1",
          "-Xcc", "-DPB_ENABLE_MALLOC=1",
        ])
      ]
    ),
    .target(name: "LDTXProgram", dependencies: ["LDTXProtos"], path: "LDTXProgram"),
    .target(
      name: "LDTXWorkspaceBundleFormat", dependencies: ["LDTXProtos"],
      path: "LDTXWorkspaceBundleFormat"
    ),
    .target(name: "LDTXRecordBundleFormat", path: "LDTXRecordBundleFormat"),
    .testTarget(
      name: "LDTXCorelibsTests",
      dependencies: [
        "LDTXProtos", "LDTXProgram", "LDTXWorkspaceBundleFormat", "LDTXRecordBundleFormat",
      ],
      path: "Tests"
    ),
  ]
)
