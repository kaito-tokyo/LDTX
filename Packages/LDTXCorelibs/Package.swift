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
  dependencies: [],
  targets: [
    .target(
      name: "nanopb",
      path: "Sources/nanopb",
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("include")]
    ),
    .target(
      name: "LDTXNanopbGenerated",
      dependencies: ["nanopb"],
      path: "Sources/LDTXNanopbGenerated",
      publicHeadersPath: "include"
    ),
    .target(
      name: "LDTXMessages",
      dependencies: [
        "LDTXNanopbGenerated",
        "nanopb",
      ],
      path: "Sources/LDTXMessages"
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
