// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
  name: "LDTXFontRasterizer",
  products: [
    .library(
      name: "LDTXFontRasterizer", type: .dynamic,
      targets: ["LDTXFontRasterizer"])
  ],
  targets: [
    .target(
      name: "LDTXFontRasterizer",
      path: "Sources/LDTXFontRasterizer",
      publicHeadersPath: "include")
  ])
