// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import LDTXProtos

extension Ldtx_Workspace_V4_VisionRegionOfInterest {
  /// Projects normalized coordinates into the supplied image extent.
  /// Uses its bottom-left origin and actual size without clipping.
  public func rect(in imageExtent: CGRect) -> CGRect {
    CGRect(
      x: imageExtent.minX + imageExtent.width * CGFloat(x.double),
      y: imageExtent.minY + imageExtent.height * CGFloat(y.double),
      width: imageExtent.width * CGFloat(width.double),
      height: imageExtent.height * CGFloat(height.double))
  }
}
