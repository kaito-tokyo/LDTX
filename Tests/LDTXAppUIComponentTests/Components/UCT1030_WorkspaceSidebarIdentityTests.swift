// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1030: Sidebar row identity", .serialized)
  @MainActor
  struct UCT1030WorkspaceSidebarIdentityUnitTestSuite {
    @Test("LUB-1048: Invalid and duplicate IDs get distinct negative, unselectable row IDs")
    func invalidRows() {
      let ids: [Int64?] = [11, nil, 0, -1, 7, 7, 21]
      let rows = WorkspaceSidebar.rows(ids) { $0 }
      #expect(rows.map(\.id) == [11, -2, -3, -4, -5, -6, 21])
      #expect(rows.map(\.isSelectable) == [true, false, false, false, false, false, true])
      #expect(Set(rows.map(\.id)).count == rows.count)
      #expect(rows.map(\.value) == ids)
    }

    @Test("LUB-1048: Valid row IDs survive reordering")
    func reorderedRows() {
      let ids: [Int64?] = [11, nil, 21]
      let before = WorkspaceSidebar.rows(ids) { $0 }
      let after = WorkspaceSidebar.rows(Array(ids.reversed())) { $0 }
      #expect(before.filter(\.isSelectable).map(\.id) == [11, 21])
      #expect(after.filter(\.isSelectable).map(\.id) == [21, 11])
    }

    @Test("LUB-1048: Temporary UI identities never modify Proto IDs or their presence")
    func preservesProtoValues() {
      let visions: [Ldtx_Workspace_V4_VisionWrapper] = [
        .init(), .with { $0.ocrVision = .init() },
        .with { $0.ocrVision.internalID = 0 },
        .with { $0.ocrVision.internalID = -1 },
        .with { $0.ocrVision.internalID = 11 },
      ]
      let rows = WorkspaceSidebar.rows(visions) { $0.internalID }
      #expect(rows.map(\.id) == [-1, -2, -3, -4, 11])
      #expect(rows.map(\.value) == visions)
      #expect(rows.map(\.isSelectable) == [false, false, false, false, true])
    }
  }
}
