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
      targets: ["LDTXCorelibs"]
    )
  ],
  dependencies: [
    .package(path: "../../Vendors/nanopb")
  ],
  targets: [
    .target(
      name: "LDTXNanopbGenerated",
      dependencies: [
        .product(name: "nanopb", package: "nanopb")
      ],
      path: "Sources/LDTXNanopbGenerated",
      publicHeadersPath: "include",
      cSettings: [
        .define("PB_FIELD_32BIT", to: "1"),
        .define("PB_NO_PACKED_STRUCTS", to: "1"),
        .define("PB_ENABLE_MALLOC", to: "1"),
      ]
    ),
    .target(
      name: "LDTXMessages",
      dependencies: [
        "LDTXNanopbGenerated",
        .product(name: "nanopb", package: "nanopb"),
      ],
      path: "Sources/LDTXMessages",
      swiftSettings: [
        .unsafeFlags([
          "-Xcc", "-DPB_FIELD_32BIT=1",
          "-Xcc", "-DPB_NO_PACKED_STRUCTS=1",
          "-Xcc", "-DPB_ENABLE_MALLOC=1",
        ])
      ]
    ),
    .target(
      name: "LDTXCorelibs",
      dependencies: ["LDTXMessages"],
      path: "Sources/LDTXCorelibs"
    ),
    .testTarget(
      name: "LDTXCorelibsTests",
      dependencies: ["LDTXCorelibs", "LDTXMessages"],
      path: "Tests/LDTXCorelibsTests"
    ),
  ]
)
