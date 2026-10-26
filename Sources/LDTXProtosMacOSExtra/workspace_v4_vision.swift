// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import LDTXCorelibs

extension Ldtx_Workspace_V4_VisionRegionOfInterest {
  /// Projects normalized coordinates into the supplied image extent.
  /// Uses its bottom-left origin and actual size without clipping.
  public func rect(in imageExtent: CGRect) -> CGRect {
    CGRect(
      x: imageExtent.minX + imageExtent.width
        * CGFloat(x?.double(defaultNumerator: 0, defaultDenominator: 1) ?? 0),
      y: imageExtent.minY + imageExtent.height
        * CGFloat(y?.double(defaultNumerator: 0, defaultDenominator: 1) ?? 0),
      width: imageExtent.width
        * CGFloat(width?.double(defaultNumerator: 1, defaultDenominator: 1) ?? 1),
      height: imageExtent.height
        * CGFloat(height?.double(defaultNumerator: 1, defaultDenominator: 1) ?? 1))
  }
}
