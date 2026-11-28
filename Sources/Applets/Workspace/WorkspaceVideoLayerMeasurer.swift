// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import LDTXCorelibs
import LDTXProgramRuntime
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletService

/// Measures Video Layers with the same metrics the overlay producer uses.
@MainActor
final class WorkspaceVideoLayerMeasurer: VideoLayerMeasuring {
  func naturalPixelSize(of clock: Ldtx_Workspace_V4_ClockComponent) -> CGSize? {
    ClockOverlayMetrics.naturalPixelSize(for: WorkspaceV4RenderGraph.clockComponent(clock))
      .map { CGSize(width: CGFloat($0.x), height: CGFloat($0.y)) }
  }
}
