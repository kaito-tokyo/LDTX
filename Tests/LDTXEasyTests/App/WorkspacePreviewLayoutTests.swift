// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
@testable import LDTXWorkspaceAppletUI
import Testing

@Suite struct WorkspacePreviewLayoutUnitTestSuite {
  @Test(arguments: [
    CGSize(width: 600, height: 700), CGSize(width: 160, height: 700),
    CGSize(width: 1000, height: 100), CGSize.zero, CGSize(width: 20, height: 50),
  ])
  func fitsPairAndReservesEditorSpace(_ container: CGSize) {
    for count in [0, 1, 4, 30] {
      let selectionHeight = WorkspacePreviewLayout.selectionHeight(
        programCount: count, in: container)
      #expect(selectionHeight <= min(40, max(0, container.height)))
      if count > 0 {
        #expect(
          selectionHeight == WorkspacePreviewLayout.selectionHeight(programCount: 1, in: container))
      }
      if count == 0 { #expect(selectionHeight == 0) }
      let size = WorkspacePreviewLayout.size(in: container, selectionHeight: selectionHeight)
      #expect(size.width >= 0 && size.height >= 0)
      #expect(size.width <= max(0, container.width - 40) + 0.001)
      #expect(size.height <= container.height * 0.45 + 0.001)
      #expect(
        size.height <= max(0, container.height - selectionHeight) * 0.45
          + 0.001)
      #expect(abs(size.width - size.height * (16.0 / 9.0 + 9.0 / 16.0)) < 0.001)
    }
  }
}
