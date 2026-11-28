// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs

/// Measures Clock overlays the way the overlay producer sizes their textures.
public enum ClockOverlayMetrics {
  /// The unscaled Clock size in output pixels, before the layer scale applies.
  /// Nil when the Clock has no font size or exceeds the rendering limits.
  public static func naturalPixelSize(for component: ClockComponent) -> SIMD2<Float>? {
    MetalClockOverlayRenderer.bundledNaturalClockSize(for: component)
  }
}
