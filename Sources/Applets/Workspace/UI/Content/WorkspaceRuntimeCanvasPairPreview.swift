// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import LDTXWorkspaceAppletInterface
import SwiftUI

/// Displays a Landscape and Portrait pair backed by already-configured Program
/// runtimes. It does not require a Workspace persistence model.
public struct WorkspaceRuntimeCanvasPairPreview: View {
  private let landscapeRuntime: ProgramRuntime
  private let portraitRuntime: ProgramRuntime
  private let landscapeSize: CGSize
  private let portraitSize: CGSize

  public init(
    landscapeRuntime: ProgramRuntime,
    portraitRuntime: ProgramRuntime,
    landscapeSize: CGSize,
    portraitSize: CGSize
  ) {
    self.landscapeRuntime = landscapeRuntime
    self.portraitRuntime = portraitRuntime
    self.landscapeSize = landscapeSize
    self.portraitSize = portraitSize
  }

  public var body: some View {
    CanvasPairPreview(
      prefersColor: .constant(true),
      landscapeRuntime: landscapeRuntime,
      portraitRuntime: portraitRuntime,
      landscapeSize: landscapeSize,
      portraitSize: portraitSize
    )
  }
}

/// Fits the pair inside the Content pane while reserving space for its editor.
enum WorkspacePreviewLayout {
  static let aspectRatio: CGFloat = 16.0 / 9.0 + 9.0 / 16.0

  static func selectionHeight(programCount: Int, in container: CGSize) -> CGFloat {
    guard programCount > 0 else { return 0 }
    return min(40, max(0, container.height))
  }

  static func size(in container: CGSize, selectionHeight: CGFloat = 0) -> CGSize {
    let availableWidth = max(0, container.width - 40)
    let height = min(
      max(0, container.height) * 0.45, availableWidth / aspectRatio,
      max(0, container.height - selectionHeight) * 0.45)
    return CGSize(width: height * aspectRatio, height: height)
  }
}
