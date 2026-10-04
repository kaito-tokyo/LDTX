// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface
import SwiftUI

struct VideoLayersTable: NSViewRepresentable {
  let layerIDs: [UInt64]
  let programPreferences: Ldtx_Workspace_V4_ProgramPreferences
  let definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  let canvasWidth: Double
  let canvasHeight: Double
  let isLayerFrozen: Bool
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
  var isLayerFrozen = false
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
    isLayerFrozen = input.isLayerFrozen
    onAction = input.onAction
    // Keep cell identity, field editors, and uncommitted text across model updates.
    let previousIDs = layerIDs
    layerIDs = input.layerIDs
    for (index, id) in layerIDs.enumerated() {
      let cell = rows[id] ?? VideoLayerRowView(internalID: id)
      rows[id] = cell
      cell.configure(
        definition: input.definition,
        programPreferences: input.programPreferences,
        canvasWidth: input.canvasWidth, canvasHeight: input.canvasHeight,
        canMoveUp: !isLayerFrozen && index > 0,
        canMoveDown: !isLayerFrozen && index < layerIDs.count - 1,
        canRemove: !isLayerFrozen, onAction: input.onAction,
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
    guard !isLayerFrozen, rowIndexes.count == 1, let row = rowIndexes.first,
      layerIDs.indices.contains(row), let cell = rows[layerIDs[row]],
      cell.handle.bounds.contains(cell.handle.convert(mouseDownPoint, from: self))
    else { return false }
    return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
  }

  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting?
  {
    guard !isLayerFrozen, layerIDs.indices.contains(row) else { return nil }
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
    guard !isLayerFrozen, info.draggingSource as? VideoLayersTableView === self,
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

#if DEBUG
  #Preview("Video Layers Table") {
    @Previewable @State var layerIDs: [UInt64] = [1, 2, 3]
    @Previewable @State var programPreferences: Ldtx_Workspace_V4_ProgramPreferences = {
      var programPreferences = Ldtx_Workspace_V4_ProgramPreferences()
      for id: UInt64 in [1, 2, 3] {
        var transform = Ldtx_Workspace_V4_BasicTransform()
        transform.scaleX = 1
        transform.scaleY = 1
        programPreferences.videoLayerTransforms[id] = transform
      }
      programPreferences.videoLayerHidden[2] = true
      return programPreferences
    }()

    VideoLayersTable(
      layerIDs: layerIDs,
      programPreferences: programPreferences,
      definition: {
        var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
        definition.inputDevices = ["Camera", "Background", "Clock"].enumerated().map {
          index, name in
          var device = Ldtx_Workspace_V4_VideoInputDevice()
          device.internalID = UInt64(index + 1)
          device.displayName = name
          var wrapper = Ldtx_Workspace_V4_InputDeviceWrapper()
          wrapper.videoDevice = device
          return wrapper
        }
        return definition
      }(),
      canvasWidth: 1920, canvasHeight: 1080,
      isLayerFrozen: false,
      onAction: { id, action in
        switch action {
        case .move(let offsets, let destination):
          layerIDs.move(fromOffsets: offsets, toOffset: destination)
        case .moveUp:
          if let index = layerIDs.firstIndex(of: id), index > 0 {
            layerIDs.swapAt(index, index - 1)
          }
        case .moveDown:
          if let index = layerIDs.firstIndex(of: id), index + 1 < layerIDs.count {
            layerIDs.swapAt(index, index + 1)
          }
        case .hide: programPreferences.videoLayerHidden[id] = true
        case .show: programPreferences.videoLayerHidden[id] = false
        case .remove: layerIDs.removeAll { $0 == id }
        case .add: layerIDs.append(id)
        }
      },
      onCommitTransform: { id, transform in
        programPreferences.videoLayerTransforms[id] = transform
      }
    )
    .frame(
      height: CGFloat(layerIDs.count) * VideoLayersTableView.layerRowHeight
        + VideoLayersTableView.dropAreaHeight
    )
    .padding()
    .frame(width: 720)
  }
#endif
