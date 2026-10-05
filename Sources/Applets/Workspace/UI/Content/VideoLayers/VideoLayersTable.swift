// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface

struct VideoLayersTableInput {
  let layerIDs: [UInt64]
  let programPreferences: Ldtx_Workspace_V4_ProgramPreferences
  let definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  let canvasWidth: Double
  let canvasHeight: Double
  var preferences: () throws -> Ldtx_Workspace_V4_ProgramPreferences = { .init() }
  var onCommitPreferences: (Ldtx_Workspace_V4_ProgramPreferences) throws -> Void = { _ in }
  var onCommitLayerOrder: ([UInt64]) throws -> Void = { _ in }
  var onError: (Error) -> Void = { _ in }
}

final class VideoLayersTableContainer: NSScrollView {
  let table = VideoLayersTableView()
  init() {
    super.init(frame: .zero)
    hasVerticalScroller = true
    table.autoresizingMask = [.width]
    documentView = table
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

class VideoLayersTableView: NSTableView {
  static let layerRowHeight: CGFloat = 96
  static let pasteboardType = NSPasteboard.PasteboardType("tokyo.kaito.ldtx.video-layer")
  private(set) var layerIDs: [UInt64] = []
  private(set) var rows: [UInt64: VideoLayerRowView] = [:]
  private var onCommitLayerOrder: ([UInt64]) throws -> Void = { _ in }
  private var onError: (Error) -> Void = { _ in }

  init() {
    super.init(frame: .zero)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
    addTableColumn(column)
    headerView = nil
    rowHeight = Self.layerRowHeight
    intercellSpacing = .zero
    dataSource = self
    delegate = self
    registerForDraggedTypes([Self.pasteboardType])
    setDraggingSourceOperationMask(.move, forLocal: true)
    setDraggingSourceOperationMask([], forLocal: false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(_ input: VideoLayersTableInput) {
    onCommitLayerOrder = input.onCommitLayerOrder
    onError = input.onError
    // Keep cell identity, field editors, and uncommitted text across model updates.
    let previousIDs = layerIDs
    layerIDs = input.layerIDs
    configureRows(input)
    synchronizeRows(from: previousIDs)
  }

  private func configureRows(_ input: VideoLayersTableInput) {
    for id in layerIDs {
      let cell = rows[id] ?? VideoLayerRowView(internalID: id)
      rows[id] = cell
      cell.configure(
        definition: input.definition,
        programPreferences: input.programPreferences,
        canvasWidth: input.canvasWidth, canvasHeight: input.canvasHeight,
        preferences: input.preferences,
        onCommitPreferences: input.onCommitPreferences, onError: input.onError)
    }
  }

  private func synchronizeRows(from previousIDs: [UInt64]) {
    guard previousIDs != layerIDs else { return }
    guard !previousIDs.isEmpty else {
      reloadData()
      return
    }

    let retainedIDs = Set(layerIDs)
    var orderedIDs = previousIDs
    beginUpdates()
    defer { endUpdates() }
    for index in orderedIDs.indices.reversed() where !retainedIDs.contains(orderedIDs[index]) {
      rows.removeValue(forKey: orderedIDs.remove(at: index))
      removeRows(at: IndexSet(integer: index), withAnimation: [])
    }
    for (index, id) in layerIDs.enumerated() {
      if let old = orderedIDs.firstIndex(of: id) {
        guard old != index else { continue }
        orderedIDs.remove(at: old)
        orderedIDs.insert(id, at: index)
        moveRow(at: old, to: index)
      } else {
        orderedIDs.insert(id, at: index)
        insertRows(at: IndexSet(integer: index), withAnimation: [])
      }
    }
  }

  override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
    guard rowIndexes.count == 1, let row = rowIndexes.first,
      layerIDs.indices.contains(row), let cell = rows[layerIDs[row]],
      cell.handle.bounds.contains(cell.handle.convert(mouseDownPoint, from: self))
    else { return false }
    return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
  }

  private func dropSourceRow(_ info: NSDraggingInfo, destination: Int) -> Int? {
    guard info.draggingSource as? VideoLayersTableView === self,
      (0...layerIDs.count).contains(destination),
      info.draggingPasteboard.pasteboardItems?.count == 1,
      let value = info.draggingPasteboard.string(forType: Self.pasteboardType),
      let id = UInt64(value), let source = layerIDs.firstIndex(of: id)
    else { return nil }
    return source
  }

}

extension VideoLayersTableView: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int { layerIDs.count }

  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting?
  {
    guard layerIDs.indices.contains(row) else { return nil }
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
    var reordered = layerIDs
    let id = reordered.remove(at: source)
    reordered.insert(id, at: source < row ? row - 1 : row)
    do {
      try onCommitLayerOrder(reordered)
      return true
    } catch {
      onError(error)
      return false
    }
  }
}

extension VideoLayersTableView: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard layerIDs.indices.contains(row) else { return nil }
    return rows[layerIDs[row]]
  }

}
