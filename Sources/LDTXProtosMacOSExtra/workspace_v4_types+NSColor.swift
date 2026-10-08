// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos

extension Ldtx_Workspace_V4_Color {
  /// Interprets RGBA components, including protobuf defaults, as extended sRGB.
  /// RGB values are not clamped.
  public var extendedSRGBNSColor: NSColor? {
    return NSColor(
      colorSpace: .extendedSRGB,
      components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)],
      count: 4)
  }

  /// Converts the supplied color to extended sRGB and sets all four components.
  /// Returns nil if AppKit cannot convert the color to that color space.
  public init?(extendedSRGBNSColor color: NSColor) {
    guard let converted = color.usingColorSpace(.extendedSRGB) else { return nil }
    self.init()
    red = Float(converted.redComponent)
    green = Float(converted.greenComponent)
    blue = Float(converted.blueComponent)
    alpha = Float(converted.alphaComponent)
  }
}
