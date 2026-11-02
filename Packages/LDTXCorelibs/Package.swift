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
      publicHeadersPath: "include",
      cSettings: [
        // The generated C headers include nanopb's public headers as <pb.h>.
        // SwiftPM forwards target dependencies for normal package builds, but
        // Xcode's package integration also needs this direct C include path.
        .headerSearchPath("../nanopb/include")
      ]
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
