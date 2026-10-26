// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
import SwiftUI

extension Ldtx_Workspace_V4_Color {
  /// Interprets missing RGBA components as zero in extended sRGB.
  /// RGB values are not clamped.
  public var extendedSRGBNSColor: NSColor? {
    return NSColor(
      colorSpace: .extendedSRGB,
      components: [
        CGFloat(red ?? 0), CGFloat(green ?? 0), CGFloat(blue ?? 0), CGFloat(alpha ?? 0),
      ],
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

extension Ldtx_Workspace_V4_Color {
  /// Interprets missing RGBA components as zero in extended sRGB for SwiftUI.
  public var extendedSRGBSwiftUIColor: SwiftUI.Color? {
    extendedSRGBNSColor.map { SwiftUI.Color(nsColor: $0) }
  }

  /// Converts a SwiftUI color to extended sRGB and sets all four components.
  public init?(extendedSRGBSwiftUIColor color: SwiftUI.Color) {
    self.init(extendedSRGBNSColor: NSColor(color))
  }
}
