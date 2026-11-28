// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import LDTXCorelibs

/// Measures Video Layers whose size only the renderer knows, so the preview can
/// outline them. The composition root supplies the rendering implementation.
@MainActor
public protocol VideoLayerMeasuring: AnyObject {
  /// The Clock's size at scale 1, in output pixels, or nil when it cannot be rendered.
  func naturalPixelSize(of clock: Ldtx_Workspace_V4_ClockComponent) -> CGSize?
}
