// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface

class VideoLayersTableView: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
  static let dragRegionHeight: CGFloat = 28
  static let pasteboardType = NSPasteboard.PasteboardType("tokyo.kaito.ldtx.video-layer")
  private(set) var layerIDs: [UInt64] = []
  private(set) var rows: [UInt64: VideoLayersTableRow] = [:]
  private var onCommitLayerOrder: ([UInt64]) throws -> Void = { _ in }
  private var onError: (Error) -> Void = { _ in }

  init() {
    super.init(frame: .zero)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
    addTableColumn(column)
    headerView = nil
    style = .fullWidth
    usesAutomaticRowHeights = true
    intercellSpacing = .zero
    dataSource = self
    delegate = self
    registerForDraggedTypes([Self.pasteboardType])
    setDraggingSourceOperationMask(.move, forLocal: true)
    setDraggingSourceOperationMask([], forLocal: false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: NSSize {
    NSSize(
      width: NSView.noIntrinsicMetric,
      height: layerIDs.reduce(0) { $0 + (rows[$1]?.fittingSize.height ?? rowHeight) })
  }

  func removeAllRows() {
    window?.makeFirstResponder(nil)
    layerIDs = []
    rows.removeAll()
    reloadData()
    invalidateIntrinsicContentSize()
  }

  func update(
    layerIDs: [UInt64], rows: [UInt64: VideoLayersTableRow],
    onCommitLayerOrder: @escaping ([UInt64]) throws -> Void = { _ in },
    onError: @escaping (Error) -> Void = { _ in }
  ) {
    self.onCommitLayerOrder = onCommitLayerOrder
    self.onError = onError
    let previousIDs = self.layerIDs
    let replacedRows = IndexSet(
      layerIDs.indices.filter { self.rows[layerIDs[$0]] !== rows[layerIDs[$0]] })
    self.layerIDs = layerIDs
    self.rows = rows.filter { layerIDs.contains($0.key) }
    if previousIDs != layerIDs || !replacedRows.isEmpty {
      invalidateIntrinsicContentSize()
    }

    guard previousIDs != layerIDs else {
      if !replacedRows.isEmpty {
        reloadData(forRowIndexes: replacedRows, columnIndexes: IndexSet(integer: 0))
      }
      return
    }
    guard !previousIDs.isEmpty else {
      reloadData()
      return
    }

    var orderedIDs = previousIDs
    beginUpdates()
    for index in orderedIDs.indices.reversed() where !layerIDs.contains(orderedIDs[index]) {
      orderedIDs.remove(at: index)
      removeRows(at: IndexSet(integer: index), withAnimation: [])
    }
    for (index, id) in layerIDs.enumerated() {
      if let source = orderedIDs.firstIndex(of: id) {
        guard source != index else { continue }
        orderedIDs.remove(at: source)
        moveRow(at: source, to: index)
      } else {
        insertRows(at: IndexSet(integer: index), withAnimation: [])
      }
      orderedIDs.insert(id, at: index)
    }
    endUpdates()
    if !replacedRows.isEmpty {
      reloadData(forRowIndexes: replacedRows, columnIndexes: IndexSet(integer: 0))
    }
  }

  override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
    let index = row(at: mouseDownPoint)
    guard layerIDs.indices.contains(index), rowIndexes == IndexSet(integer: index),
      mouseDownPoint.y < rect(ofRow: index).minY + Self.dragRegionHeight
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
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard layerIDs.indices.contains(row) else { return nil }
    return rows[layerIDs[row]]
  }

}

#if DEBUG
  import SwiftUI

  #Preview("Video Layers Table") {
    let editor = VideoLayersEditor(
      storeService: WorkspaceStoreService(definition: .init(), preferences: .init()),
      target: .landscape)
    _ = editor.view
    editor.view.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    var preferences = Ldtx_Workspace_V4_ProgramPreferences()
    for (index, name) in ["Camera", "Background", "Clock"].enumerated() {
      let id = UInt64(index + 1)
      var device = Ldtx_Workspace_V4_VfxSourceComponent()
      device.internalID = id
      device.displayName = name
      var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
      wrapper.vfxSource = device
      definition.videoComponents.append(wrapper)
      var transform = Ldtx_Workspace_V4_BasicTransform()
      transform.scaleXRational = .with {
        $0.set(num: 1, den: 1)
      }
      transform.scaleYRational = .with {
        $0.set(num: 1, den: 1)
      }
      preferences.videoLayerTransforms[id] = transform
    }
    preferences.videoLayerHidden[2] = true
    editor.update(
      definition: definition, programPreferences: preferences, layerIDs: [1, 2, 3],
      canvasWidth: 1920, canvasHeight: 1080,
      onCommitTransform: { id, value in
        preferences.videoLayerTransforms[id] = value
        return value
      },
      onSetHidden: { id, value in preferences.videoLayerHidden[id] = value })
    return editor
  }
#endif
