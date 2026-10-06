// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import Testing

@MainActor
final class VideoLayersTestFixture {
  var editors: [ObjectIdentifier: VideoLayersEditor] = [:]
  var reportedErrors: [String] = []
  func makeEditor() -> VideoLayersEditor {
    let editor = VideoLayersEditor(
      storeService: WorkspaceStoreService(definition: .init(), preferences: .init()),
      target: .landscape)
    _ = editor.view
    return editor
  }

  func makeTable() -> VideoLayersTableView {
    let editor = makeEditor()
    editors[ObjectIdentifier(editor.table)] = editor
    return editor.table
  }

  func makeContainer() -> (scrollView: NSScrollView, table: VideoLayersTableView) {
    let table = makeTable()
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.documentView = table
    return (scrollView, table)
  }

  func update(
    _ table: VideoLayersTableView,
    ids: [UInt64] = [1, 2, 3],
    preferences: Ldtx_Workspace_V4_ProgramPreferences = .init(),
    commit: @escaping (UInt64, Ldtx_Workspace_V4_BasicTransform) throws -> Void = { _, _ in },
    order: @escaping ([UInt64]) throws -> Void = { _ in },
    setHidden: @escaping (UInt64, Bool) throws -> Void = { _, _ in },
    onError: @escaping (Error) -> Void = { _ in }
  ) {
    let editor = editors[ObjectIdentifier(table)] ?? makeEditor()
    editors[ObjectIdentifier(table)] = editor
    editor.update(
      definition: .init(), programPreferences: preferences, layerIDs: ids,
      canvasWidth: 1920, canvasHeight: 1080,
      onCommitTransform: { id, value in
        try commit(id, value)
        return value
      },
      onSetHidden: setHidden, onCommitLayerOrder: order,
      onError: { [weak self] error in
        self?.reportedErrors.append(error.localizedDescription)
        onError(error)
      })
    if editor.table !== table {
      table.update(
        layerIDs: ids, rows: editor.table.rows,
        onCommitLayerOrder: order, onError: onError)
    }
  }

  func nativeFields(in view: NSView) -> [NSTextField] {
    if let field = view as? NSTextField, field.isEditable { return [field] }
    return view.subviews.flatMap { nativeFields(in: $0) }
  }
}
@MainActor
final class LayerDraggingInfo: NSObject, NSDraggingInfo {
  let draggingSource: Any?
  let draggingPasteboard = NSPasteboard.withUniqueName()
  var draggingDestinationWindow: NSWindow? { nil }
  var draggingSourceOperationMask: NSDragOperation { .move }
  var draggingLocation: NSPoint = .zero
  var draggedImageLocation: NSPoint { .zero }
  nonisolated var draggedImage: NSImage? { nil }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }

  init(source: VideoLayersTableView, id: UInt64) {
    draggingSource = source
    super.init()
    let item = NSPasteboardItem()
    item.setString(String(id), forType: VideoLayersTableView.pasteboardType)
    draggingPasteboard.writeObjects([item])
  }

  func slideDraggedImage(to screenPoint: NSPoint) {}
  nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL)
    -> [String]?
  { nil }
  func resetSpringLoading() {}
  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions,
    for view: NSView?, classes classArray: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
}

@MainActor
final class DropRecordingTable: VideoLayersTableView {
  var insertionRow = -1
  override func setDropRow(_ row: Int, dropOperation: NSTableView.DropOperation) {
    insertionRow = row
    super.setDropRow(row, dropOperation: dropOperation)
  }
}
