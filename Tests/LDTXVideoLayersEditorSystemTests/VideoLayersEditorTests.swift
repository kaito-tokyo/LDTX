// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import Testing

@Suite(.serialized)
@MainActor
struct VideoLayersEditorTests {
  func input(
    ids: [UInt64] = [1, 2, 3],
    preferences: Ldtx_Workspace_V4_ProgramPreferences = .init(),
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 = .init(),
    commit: @escaping (UInt64, Ldtx_Workspace_V4_BasicTransform) throws -> Void = { _, _ in },
    order: @escaping ([UInt64]) throws -> Void = { _ in }
  ) -> VideoLayersTableInput {
    var current = preferences
    return VideoLayersTableInput(
      layerIDs: ids, programPreferences: preferences, definition: definition,
      canvasWidth: 1920, canvasHeight: 1080,
      preferences: { current },
      onCommitPreferences: { value in
        for (id, transform) in value.videoLayerTransforms
        where current.videoLayerTransforms[id] != transform {
          try commit(id, transform)
        }
        current = value
      }, onCommitLayerOrder: order)
  }

  @Test func resolvesAndUpdatesNamesFromDefinition() throws {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    var device = Ldtx_Workspace_V4_VideoInputDevice()
    device.internalID = 1
    device.displayName = "Camera"
    var wrapper = Ldtx_Workspace_V4_InputDeviceWrapper()
    wrapper.videoDevice = device
    definition.inputDevices = [wrapper]
    var clock = Ldtx_Workspace_V4_ClockComponent()
    clock.internalID = 3
    clock.displayName = "Clock"
    var component = Ldtx_Workspace_V4_VideoComponentWrapper()
    component.clock = clock
    definition.videoComponents = [component]
    let table = VideoLayersTableView()
    table.update(input(definition: definition))
    let row = try #require(table.rows[1])
    #expect(row.nameLabel.stringValue == "Camera")
    #expect(table.rows[3]?.nameLabel.stringValue == "Clock")
    definition.inputDevices[0].videoDevice.displayName = "Renamed"
    table.update(input(definition: definition))
    #expect(table.rows[1] === row)
    #expect(row.nameLabel.stringValue == "Renamed")
    #expect(table.rows[2]?.nameLabel.stringValue == "Missing Video Layer")
  }

  @Test func reflectsPreferencesWithoutOverwritingEditingText() throws {
    let table = VideoLayersTableView()
    table.update(input())
    let row = try #require(table.rows[1])
    var preferences = Ldtx_Workspace_V4_ProgramPreferences()
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.translationX = 0.5
    transform.scaleX = 1
    transform.scaleY = 1
    preferences.videoLayerTransforms[1] = transform
    preferences.videoLayerHidden[1] = true
    table.update(input(preferences: preferences))
    #expect(table.rows[1] === row)
    #expect(row.fields[0].stringValue == "960.0")
    #expect(row.hideButton.state == .on)
    row.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification))
    row.fields[0].stringValue = "draft"
    preferences.videoLayerTransforms[1]?.translationX = 0.25
    preferences.videoLayerHidden[1] = false
    table.update(input(preferences: preferences))
    #expect(row.fields[0].stringValue == "draft")
    #expect(row.hideButton.state == .off)
  }

  @Test func commitsNormalizedNumbersOnEnterAndFocusChange() throws {
    var saved: [Ldtx_Workspace_V4_BasicTransform] = []
    let table = VideoLayersTableView()
    table.update(input(commit: { _, value in saved.append(value) }))
    let row = try #require(table.rows[1])
    for (field, value) in zip(row.fields, ["960", "270", "1.5", "2"]) { field.stringValue = value }
    row.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(
      row.control(
        row.fields[0], textView: NSTextView(),
        doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(saved.count == 1)
    #expect(saved[0].translationX == 0.5)
    #expect(saved[0].translationY == 0.25)
    #expect(saved[0].scaleX == 1.5)
    row.fields[0].stringValue = "192"
    row.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    row.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
    #expect(saved.count == 2)
    #expect(saved[1].translationX == 0.1)
    #expect(!row.hasUnconfirmedChanges)
    #expect(
      !row.control(
        row.fields[0], textView: NSTextView(),
        doCommandBy: #selector(NSResponder.insertTab(_:))))
    #expect(
      !row.control(
        row.fields[0], textView: NSTextView(),
        doCommandBy: #selector(NSResponder.insertBacktab(_:))))
  }

  @Test(arguments: ["-", "１２", "inf", "1e100"])
  func invalidInputSurvivesModelUpdates(value: String) throws {
    var commits = 0
    let table = VideoLayersTableView()
    table.update(input(commit: { _, _ in commits += 1 }))
    let row = try #require(table.rows[1])
    row.fields[2].stringValue = value
    row.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    row.commit()
    table.update(input(ids: [3, 1, 2]))
    #expect(table.rows[1] === row)
    #expect(row.fields[2].stringValue == value)
    #expect(row.errorLabel.stringValue == "Invalid number.")
    #expect(commits == 0)
  }

  @Test func failureRetainsDraftAndCanBeRetried() throws {
    let table = VideoLayersTableView()
    table.update(
      input(commit: { _, _ in
        throw NSError(
          domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Save failed."])
      }))
    let row = try #require(table.rows[1])
    row.fields[0].stringValue = "960.000"
    row.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    row.commit()
    #expect(row.errorLabel.stringValue == "Save failed.")
    #expect(row.hasUnconfirmedChanges)
    #expect(row.fields[0].stringValue == "960.000")
    table.update(input())
    row.commit()
    #expect(!row.hasUnconfirmedChanges)
    #expect(row.fields[0].stringValue == "960.0")
  }

  @Test func onlyHandleStartsDrag() throws {
    let table = VideoLayersTableView()
    table.frame = NSRect(x: 0, y: 0, width: 720, height: 308)
    table.update(input())
    table.layoutSubtreeIfNeeded()
    let cell = try #require(
      table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? VideoLayerRowView)
    cell.layoutSubtreeIfNeeded()
    let handle = table.convert(NSPoint(x: 10, y: 10), from: cell.handle)
    #expect(table.canDragRows(with: IndexSet(integer: 0), at: handle))
    let field = table.convert(NSPoint(x: 10, y: 10), from: cell.fields[0])
    #expect(!table.canDragRows(with: IndexSet(integer: 0), at: field))
    #expect(!table.canDragRows(with: IndexSet([0, 1]), at: handle))
  }

  @Test func acceptsSingleLocalMovesAndRejectsForeign() throws {
    let table = VideoLayersTableView()
    var actions: [[UInt64]] = []
    table.update(input(order: { actions.append($0) }))
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

  @Test func lowerHalfOfLastRowTargetsEndInsertion() {
    let table = DropRecordingTable()
    table.frame = NSRect(x: 0, y: 0, width: 720, height: 308)
    var actions: [[UInt64]] = []
    table.update(input(order: { actions.append($0) }))
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

  @Test func realFieldEditorCommitsOnFocusMovementAndDisablesCorrections() throws {
    let container = VideoLayersTableContainer()
    container.frame = NSRect(x: 0, y: 0, width: 720, height: 308)
    let window = NSWindow(
      contentRect: container.frame, styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    defer { window.close() }
    var saved: [Ldtx_Workspace_V4_BasicTransform] = []
    container.table.update(input(commit: { _, value in saved.append(value) }))
    container.layoutSubtreeIfNeeded()
    let row = try #require(container.table.rows[1])
    #expect(!row.draggingImageComponents.isEmpty)
    #expect(window.makeFirstResponder(row.fields[0]))
    let editor = try #require(row.fields[0].currentEditor() as? NSTextView)
    #expect(!editor.isAutomaticSpellingCorrectionEnabled)
    #expect(!editor.isContinuousSpellCheckingEnabled)
    editor.insertText(
      "960", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    #expect(window.makeFirstResponder(row.fields[1]))
    #expect(saved.count == 1)
    #expect(saved.first?.translationX == 0.5)
    let next = try #require(row.fields[1].currentEditor() as? NSTextView)
    next.insertText("-", replacementRange: NSRange(location: 0, length: next.string.utf16.count))
    #expect(window.makeFirstResponder(container.table))
    #expect(saved.count == 1)
    #expect(row.fields[1].stringValue == "-")
    #expect(row.errorLabel.stringValue == "Invalid number.")
  }

  @Test func containerScrollsIndependentlyAndUpdatesRowsInPlace() throws {
    let container = VideoLayersTableContainer()
    container.frame = NSRect(x: 0, y: 0, width: 720, height: 308)
    container.table.update(input())
    container.layoutSubtreeIfNeeded()
    #expect(container.hasVerticalScroller)
    let first = try #require(container.table.rows[1])
    container.table.update(input(ids: [3, 1, 4]))
    #expect(container.table.rows[1] === first)
    #expect(container.table.rows[2] == nil)
    #expect(container.table.rows[4] != nil)
    #expect(container.table.layerIDs == [3, 1, 4])
    container.table.update(input(ids: []))
    #expect(container.table.rows.isEmpty)
    container.table.update(input(ids: [1]))
    #expect(container.table.rows[1] !== first)
    container.frame = NSRect(x: 0, y: 0, width: 650, height: 116)
    container.layoutSubtreeIfNeeded()
  }

  @Test func activeEditorSurvivesOrdinaryRefresh() throws {
    let table = VideoLayersTableView()
    table.update(input())
    let row = try #require(table.rows[1])
    row.controlTextDidBeginEditing(
      Notification(
        name: NSControl.textDidBeginEditingNotification,
        object: row.fields[0]))
    row.fields[0].stringValue = "192.00000286102295"
    table.update(input())
    #expect(row.fields[0].stringValue == "192.00000286102295")
    #expect(table.rows[1] === row)
    let other = VideoLayersTableView()
    other.update(input())
    #expect(other.rows[1] !== row)
  }
}

@MainActor
private final class LayerDraggingInfo: NSObject, NSDraggingInfo {
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
private final class DropRecordingTable: VideoLayersTableView {
  var insertionRow = -1
  override func setDropRow(_ row: Int, dropOperation: NSTableView.DropOperation) {
    insertionRow = row
    super.setDropRow(row, dropOperation: dropOperation)
  }
}

extension VideoLayersEditorTests {
  @Test func preferenceCommitUsesLatestValueAndPreservesInsets() throws {
    var live = Ldtx_Workspace_V4_ProgramPreferences()
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.scaleX = 1
    transform.scaleY = 1
    transform.topInset = 0.2
    live.videoLayerTransforms[1] = transform
    let table = VideoLayersTableView()
    table.update(
      VideoLayersTableInput(
        layerIDs: [1], programPreferences: live, definition: .init(),
        canvasWidth: 1920, canvasHeight: 1080, preferences: { live },
        onCommitPreferences: { live = $0 }))
    live.audioMasterVolumeDecibelTenths = -90
    let row = try #require(table.rows[1])
    row.fields[0].stringValue = "960"
    row.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: row.fields[0]))
    row.commit()
    #expect(live.audioMasterVolumeDecibelTenths == -90)
    #expect(live.videoLayerTransforms[1]?.topInset == 0.2)
    #expect(live.videoLayerTransforms[1]?.translationX == 0.5)
  }

  @Test func failedOrderCommitDoesNotAcceptDrop() {
    let table = VideoLayersTableView()
    var failures = 0
    var value = input(order: { _ in throw WorkspaceSelectionError(message: "Rejected") })
    value.onError = { _ in failures += 1 }
    table.update(value)
    #expect(
      !table.tableView(
        table, acceptDrop: LayerDraggingInfo(source: table, id: 1), row: 3, dropOperation: .above))
    #expect(table.layerIDs == [1, 2, 3])
    #expect(failures == 1)
  }

  @Test func membershipSheetRetainsDraftOnFailureAndInvalidatesExternalChanges() throws {
    let options: [WorkspaceSelectionOption<UInt64>] = [
      .init(id: 1, name: "One"), .init(id: 2, name: "Two"),
    ]
    let sheet = VideoLayersManagementSheet(ids: [1], options: options)
    #expect(sheet.checkboxes[1]?.state == .on)
    #expect(sheet.checkboxes[2]?.state == .off)
    #expect(!sheet.applyButton.isEnabled)
    try #require(sheet.checkboxes[2]).performClick(nil)
    #expect(sheet.draft.ids == [1, 2])
    var closed = false
    sheet.onClose = { closed = true }
    sheet.commit = { _, _, _ in throw WorkspaceSelectionError(message: "Failed") }
    sheet.apply()
    #expect(!closed)
    #expect(sheet.errorLabel.stringValue == "Failed")
    #expect(sheet.draft.ids == [1, 2])
    sheet.update(ids: [1], options: Array(options.prefix(1)), active: false)
    #expect(!sheet.applyButton.isEnabled)
    #expect(sheet.checkboxes[2]?.isEnabled == false)
  }

  @Test func changingProgramDiscardsDraftAndActiveOutputClosesSheet() throws {
    let editor = VideoLayersEditor()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = editor
    defer {
      editor.closeManager()
      window.close()
    }
    editor.update(programID: 1, input: input(), active: false)
    let old = try #require(editor.container.table.rows[1])
    old.fields[0].stringValue = "draft"
    old.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: old.fields[0]))
    editor.openManager()
    #expect(editor.manager != nil)
    editor.update(programID: 1, input: input(), active: true)
    #expect(editor.manager == nil)
    #expect(!editor.manageButton.isEnabled)
    editor.update(programID: 2, input: input(), active: false)
    #expect(editor.container.table.rows[1] !== old)
    #expect(editor.container.table.rows[1]?.hasUnconfirmedChanges == false)
    #expect(editor.manageButton.isEnabled)
  }

  @Test func audioNumericDraftSurvivesRefreshAndFailure() {
    let field = AudioDecibelField()
    field.configure(value: 0, enabled: true) { _ in false }
    field.stringValue = "-12.5"
    field.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: field))
    field.configure(value: -4, enabled: true) { _ in false }
    #expect(field.stringValue == "-12.5")
    field.commit()
    #expect(field.dirty)
    var committed = 0.0
    field.configure(value: -4, enabled: true) {
      committed = $0
      return true
    }
    field.commit()
    #expect(committed == -12.5)
    #expect(!field.dirty)
  }
}

extension VideoLayersEditorTests {
  @Test func monitorDeviceSheetStartsUnselectedAndClearsUnavailableDraft() throws {
    let name = "MonitorSheet-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("saved", forKey: WorkspaceAudioEngine.outputDevicePreferenceKey)
    var devices: [(uid: String, name: String)] = [("saved", "Saved Device"), ("new", "New Device")]
    let sheet = MonitorOutputDeviceSheet(defaults: defaults, deviceProvider: { devices })
    defer { sheet.stop() }
    #expect(sheet.selectedUID == nil)
    #expect(sheet.table.selectedRow == -1)
    #expect(sheet.currentLabel.stringValue == "Saved Device")
    #expect(!sheet.applyButton.isEnabled)
    sheet.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    let selected = try #require(sheet.selectedUID)
    sheet.refreshDevices()
    #expect(sheet.selectedUID == selected)
    devices.removeAll { $0.uid == selected }
    sheet.refreshDevices()
    #expect(sheet.selectedUID == nil)
    #expect(!sheet.applyButton.isEnabled)
    #expect(defaults.string(forKey: WorkspaceAudioEngine.outputDevicePreferenceKey) == "saved")
    var closed = false
    sheet.onClose = { closed = true }
    sheet.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    sheet.applyButton.performClick(nil)
    #expect(closed)
    #expect(
      defaults.string(forKey: WorkspaceAudioEngine.outputDevicePreferenceKey) == devices[0].uid)
  }
}
