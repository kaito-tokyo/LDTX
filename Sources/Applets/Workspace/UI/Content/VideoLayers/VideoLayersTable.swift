// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface
import SwiftUI

struct VideoLayersTable: NSViewRepresentable {
  let layerIDs: [UInt64]
  let transforms: [UInt64: Ldtx_Workspace_V4_BasicTransform]
  let hidden: [UInt64: Bool]
  let names: [UInt64: String]
  let width: Double
  let height: Double
  let isOutputActive: Bool
  let onAction: (UInt64, VideoLayerAction) -> Void
  let onCommitTransform: (UInt64, Ldtx_Workspace_V4_BasicTransform) throws -> Void

  func makeNSView(context: Context) -> VideoLayersTableContainer { VideoLayersTableContainer() }

  func updateNSView(_ container: VideoLayersTableContainer, context: Context) {
    container.table.update(self)
    container.needsLayout = true
  }
}

// The table needs its own clip view for AppKit drag tracking. Its viewport and
// document have equal heights; scrolling belongs to the outer SwiftUI ScrollView.
final class VideoLayersTableContainer: NSScrollView {
  let table = VideoLayersTableView()

  init() {
    super.init(frame: .zero)
    drawsBackground = false
    borderType = .noBorder
    hasVerticalScroller = false
    hasHorizontalScroller = false
    verticalScrollElasticity = .none
    horizontalScrollElasticity = .none
    documentView = table
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    table.frame = NSRect(
      x: 0, y: 0, width: contentSize.width,
      height: CGFloat(table.layerIDs.count) * VideoLayersTableView.layerRowHeight
        + (table.layerIDs.isEmpty ? 0 : VideoLayersTableView.dropAreaHeight))
  }

  override func scrollWheel(with event: NSEvent) {
    nextResponder?.scrollWheel(with: event)
  }
}

class VideoLayersTableView: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
  static let layerRowHeight: CGFloat = 96
  static let dropAreaHeight: CGFloat = 20
  static let pasteboardType = NSPasteboard.PasteboardType("tokyo.kaito.ldtx.video-layer")
  private(set) var layerIDs: [UInt64] = []
  private(set) var rows: [UInt64: VideoLayerRowView] = [:]
  var isOutputActive = false
  var onAction: (UInt64, VideoLayerAction) -> Void = { _, _ in }

  init() {
    super.init(frame: .zero)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
    column.resizingMask = .autoresizingMask
    column.isEditable = false
    addTableColumn(column)
    headerView = nil
    rowHeight = Self.layerRowHeight
    intercellSpacing = .zero
    columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    selectionHighlightStyle = .none
    verticalMotionCanBeginDrag = true
    backgroundColor = .clear
    focusRingType = .none
    dataSource = self
    delegate = self
    registerForDraggedTypes([Self.pasteboardType])
    setDraggingSourceOperationMask(.move, forLocal: true)
    setDraggingSourceOperationMask([], forLocal: false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(_ input: VideoLayersTable) {
    isOutputActive = input.isOutputActive
    onAction = input.onAction
    // Keep cell identity, field editors, and uncommitted text across model updates.
    let previousIDs = layerIDs
    layerIDs = input.layerIDs
    for (index, id) in layerIDs.enumerated() {
      let cell = rows[id] ?? VideoLayerRowView(internalID: id)
      rows[id] = cell
      cell.configure(
        name: input.names[id] ?? "Missing Video Layer", transform: input.transforms[id] ?? .init(),
        width: input.width, height: input.height, hidden: input.hidden[id] ?? false,
        canMoveUp: !isOutputActive && index > 0,
        canMoveDown: !isOutputActive && index < layerIDs.count - 1,
        canRemove: !isOutputActive, onAction: input.onAction,
        onCommitTransform: input.onCommitTransform)
    }
    if previousIDs != layerIDs {
      if previousIDs.isEmpty {
        reloadData()
      } else {
        var orderedIDs = previousIDs
        beginUpdates()
        for index in orderedIDs.indices.reversed() where !layerIDs.contains(orderedIDs[index]) {
          rows.removeValue(forKey: orderedIDs.remove(at: index))
          removeRows(at: IndexSet(integer: index), withAnimation: [])
        }
        for (index, id) in layerIDs.enumerated() {
          if let old = orderedIDs.firstIndex(of: id) {
            if old != index {
              orderedIDs.remove(at: old)
              orderedIDs.insert(id, at: index)
              moveRow(at: old, to: index)
            }
          } else {
            orderedIDs.insert(id, at: index)
            insertRows(at: IndexSet(integer: index), withAnimation: [])
          }
        }
        endUpdates()
      }
    }
    // Materialize cells only after their callbacks and initial values are configured.
    for index in layerIDs.indices { _ = view(atColumn: 0, row: index, makeIfNecessary: true) }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { layerIDs.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard layerIDs.indices.contains(row) else { return nil }
    let id = layerIDs[row]
    let cell = rows[id] ?? VideoLayerRowView(internalID: id)
    rows[id] = cell
    return cell
  }

  override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
    guard !isOutputActive, rowIndexes.count == 1, let row = rowIndexes.first,
      layerIDs.indices.contains(row), let cell = rows[layerIDs[row]],
      cell.handle.bounds.contains(cell.handle.convert(mouseDownPoint, from: self))
    else { return false }
    return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
  }

  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting?
  {
    guard !isOutputActive, layerIDs.indices.contains(row) else { return nil }
    let item = NSPasteboardItem()
    item.setString(String(layerIDs[row]), forType: Self.pasteboardType)
    return item
  }

  func tableView(
    _ tableView: NSTableView, draggingSession session: NSDraggingSession,
    willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet
  ) {
    window?.makeFirstResponder(self)
  }

  func dropSourceRow(_ info: NSDraggingInfo, destination: Int) -> Int? {
    guard !isOutputActive, info.draggingSource as? VideoLayersTableView === self,
      (0...layerIDs.count).contains(destination),
      info.draggingPasteboard.pasteboardItems?.count == 1,
      let value = info.draggingPasteboard.string(forType: Self.pasteboardType),
      let id = UInt64(value), let source = layerIDs.firstIndex(of: id)
    else { return nil }
    return source
  }

  func tableView(
    _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
    proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
  ) -> NSDragOperation {
    guard dropSourceRow(info, destination: row) != nil else { return [] }
    let point = convert(info.draggingLocation, from: nil)
    let insertionRow =
      dropOperation == .on && layerIDs.indices.contains(row)
        && point.y >= rect(ofRow: row).midY ? row + 1 : row
    setDropRow(insertionRow, dropOperation: .above)
    return .move
  }

  func tableView(
    _ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
    row: Int, dropOperation: NSTableView.DropOperation
  ) -> Bool {
    guard dropOperation == .above, let source = dropSourceRow(info, destination: row) else {
      return false
    }
    onAction(layerIDs[source], .move(fromOffsets: IndexSet(integer: source), toOffset: row))
    return true
  }
}
