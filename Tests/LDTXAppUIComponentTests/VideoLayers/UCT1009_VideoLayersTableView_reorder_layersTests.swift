// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1009: reorder-layers", .serialized)
  @MainActor
  struct UCT1009VideoLayersTableViewIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }
    @Test("UCT-1009.1: Uses standard row dragging")
    func usesStandardRowDragging() throws {
      let fixture = VideoLayersTestFixture()
      let container = fixture.makeContainer()
      let table = container.table
      container.scrollView.frame = NSRect(x: 0, y: 0, width: 720, height: 308)
      let window = NSWindow(
        contentRect: container.scrollView.frame, styleMask: [.titled], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = container.scrollView
      defer { window.close() }
      fixture.update(table)
      window.displayIfNeeded()
      container.scrollView.layoutSubtreeIfNeeded()
      let cell = try #require(
        table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? VideoLayersTableRow)
      cell.layoutSubtreeIfNeeded()
      let name = table.convert(NSPoint(x: 10, y: 10), from: cell)
      #expect(table.canDragRows(with: IndexSet(integer: 0), at: name))
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      table.layoutSubtreeIfNeeded()
      let bounds = table.rect(ofRow: 0)
      let boundary = bounds.minY + VideoLayersTableView.dragRegionHeight
      #expect(
        table.canDragRows(
          with: IndexSet(integer: 0), at: NSPoint(x: bounds.midX, y: boundary - 1)))
      #expect(
        !table.canDragRows(
          with: IndexSet(integer: 0), at: NSPoint(x: bounds.midX, y: boundary)))
      #expect(
        !table.canDragRows(
          with: IndexSet(integer: 0), at: NSPoint(x: bounds.midX, y: bounds.maxY - 1)))

    }

    @Test("UCT-1009.2: Accepts single local moves and rejects foreign")
    func acceptsSingleLocalMovesAndRejectsForeign() throws {
      let fixture = VideoLayersTestFixture()
      let table = fixture.makeTable()
      var actions: [[UInt64]] = []
      fixture.update(table, order: { actions.append($0) })
      let info = LayerDraggingInfo(source: table, id: 3)
      #expect(
        table.tableView(
          table, validateDrop: info, proposedRow: 0,
          proposedDropOperation: .above) == .move)
      #expect(table.tableView(table, acceptDrop: info, row: 0, dropOperation: .above))
      #expect(actions.count == 1)
      #expect(
        actions[0] == [3, 1, 2])
      let toEnd = LayerDraggingInfo(source: table, id: 1)
      #expect(table.tableView(table, acceptDrop: toEnd, row: 3, dropOperation: .above))
      #expect(actions[1] == [2, 3, 1])
      #expect(table.tableView(table, acceptDrop: toEnd, row: 2, dropOperation: .above))
      #expect(actions[2] == [2, 1, 3])
      let foreign = LayerDraggingInfo(source: VideoLayersTableView(), id: 1)
      #expect(!table.tableView(table, acceptDrop: foreign, row: 0, dropOperation: .above))
      let missing = LayerDraggingInfo(source: table, id: 999)
      #expect(!table.tableView(table, acceptDrop: missing, row: 0, dropOperation: .above))
      #expect(!table.tableView(table, acceptDrop: toEnd, row: 4, dropOperation: .above))
      #expect(!table.tableView(table, acceptDrop: toEnd, row: 1, dropOperation: .on))

    }

    @Test("UCT-1009.3: Lower half of last row targets end insertion")
    func lowerHalfOfLastRowTargetsEndInsertion() {
      let fixture = VideoLayersTestFixture()
      let table = DropRecordingTable()
      table.frame = NSRect(x: 0, y: 0, width: 720, height: 308)
      var actions: [[UInt64]] = []
      fixture.update(table, order: { actions.append($0) })
      let info = LayerDraggingInfo(source: table, id: 1)
      info.draggingLocation = table.convert(
        NSPoint(x: 40, y: table.rect(ofRow: 2).midY + 1), to: nil)
      #expect(
        table.tableView(
          table, validateDrop: info, proposedRow: 2,
          proposedDropOperation: .on) == .move)
      #expect(table.insertionRow == 3)
      #expect(
        table.tableView(table, acceptDrop: info, row: table.insertionRow, dropOperation: .above))
      #expect(actions == [[2, 3, 1]])
      info.draggingLocation = table.convert(
        NSPoint(x: 40, y: table.rect(ofRow: 2).midY - 1), to: nil)
      #expect(
        table.tableView(
          table, validateDrop: info, proposedRow: 2,
          proposedDropOperation: .on) == .move)
      #expect(table.insertionRow == 2)
      #expect(
        table.tableView(
          table, validateDrop: info, proposedRow: 3,
          proposedDropOperation: .above) == .move)
      #expect(table.insertionRow == 3)
    }

    @Test("UCT-1009.4: Container scrolls independently and updates rows in place")
    func containerScrollsIndependentlyAndUpdatesRowsInPlace() throws {
      let fixture = VideoLayersTestFixture()
      let container = fixture.makeContainer()
      container.scrollView.frame = NSRect(x: 0, y: 0, width: 720, height: 308)
      fixture.update(container.table)
      container.scrollView.layoutSubtreeIfNeeded()
      #expect(container.scrollView.hasVerticalScroller)
      #expect(container.table.frame.width == container.scrollView.contentSize.width)
      // The full-width AppKit style retains a small standard cell gutter.
      #expect(container.table.tableColumns[0].width >= container.scrollView.contentSize.width - 16)
      let first = try #require(container.table.rows[1])
      fixture.update(container.table, ids: [3, 1, 4])
      #expect(container.table.rows[1] === first)
      #expect(container.table.rows[2] == nil)
      #expect(container.table.rows[4] != nil)
      #expect(container.table.layerIDs == [3, 1, 4])
      fixture.update(container.table, ids: [])
      #expect(container.table.rows.isEmpty)
      fixture.update(container.table, ids: [1])
      #expect(container.table.rows[1] !== first)
      container.scrollView.frame = NSRect(x: 0, y: 0, width: 650, height: 116)
      container.scrollView.layoutSubtreeIfNeeded()
      #expect(container.table.frame.width == container.scrollView.contentSize.width)
      // The full-width AppKit style retains a small standard cell gutter.
      #expect(container.table.tableColumns[0].width >= container.scrollView.contentSize.width - 16)
    }

    @Test("UCT-1009.5: Mixed membership and order updates keep retained rows")
    func mixedMembershipAndOrderUpdatesKeepRetainedRows() throws {
      let fixture = VideoLayersTestFixture()
      let container = fixture.makeContainer()
      container.scrollView.frame = NSRect(x: 0, y: 0, width: 720, height: 500)
      let table = container.table
      fixture.update(table, ids: [1, 2, 3, 4])
      container.scrollView.layoutSubtreeIfNeeded()
      for index in 0..<4 { _ = table.view(atColumn: 0, row: index, makeIfNecessary: true) }
      let retained = try #require(table.rows[3])
      retained.state.strings[0] = "draft"
      retained.state.hasUnconfirmedChanges = true
      for ids: [UInt64] in [[4, 3, 1, 2], [5, 3, 2], [2, 5, 3, 6], []] {
        fixture.update(table, ids: ids)
        container.scrollView.layoutSubtreeIfNeeded()
        #expect(table.numberOfRows == ids.count)
        for (index, id) in ids.enumerated() {
          let row = try #require(
            table.view(atColumn: 0, row: index, makeIfNecessary: true) as? VideoLayersTableRow)
          #expect(row === table.rows[id])
        }
        if ids.contains(3) {
          #expect(table.rows[3] === retained)
          #expect(retained.state.strings[0] == "draft")
        }
      }
      #expect(table.rows.isEmpty)
    }

    @Test("UCT-1009.6: Failed order commit does not accept drop")
    func failedOrderCommitDoesNotAcceptDrop() {
      let fixture = VideoLayersTestFixture()
      let table = fixture.makeTable()
      var failures = 0
      fixture.update(
        table, order: { _ in throw WorkspaceSelectionError(message: "Rejected") },
        onError: { _ in failures += 1 })
      #expect(
        !table.tableView(
          table, acceptDrop: LayerDraggingInfo(source: table, id: 1), row: 3, dropOperation: .above)
      )
      #expect(table.layerIDs == [1, 2, 3])
      #expect(failures == 1)
    }

  }
}
