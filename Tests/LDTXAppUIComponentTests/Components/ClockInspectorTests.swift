// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
import LDTXProtosMacOSExtra
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("Clock Inspector outline editing", .serialized)
  @MainActor
  struct ClockInspectorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test func repeatedEditsHistoryAndPersistence() async throws {
      let document = WorkspaceDocument(definition: .init(), preferences: .init())
      document.editWorkspace(undoManager: nil) {
        $0.definition.videoComponents = [WorkspaceResourceFactory.makeClock(id: 11, name: "Clock")]
      }
      let view = ClockInspector(
        stateService: document, appletData: WorkspaceAppletData(), internalID: 11)
      let undo = UndoManager()
      undo.groupsByEvent = false
      func edit(_ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
      }
      let original = document.workspace
      edit { view.addOutline(undoManager: undo) }
      let width = view.outlineBinding(at: 0, \.thickness, initial: .init(), undoManager: undo)
      let color = view.outlineColorBinding(at: 0, undoManager: undo)
      for numerator in [0, 3, 7] {
        edit { width.wrappedValue = .with { $0.set(num: Int32(numerator), den: 2) } }
        #expect(width.wrappedValue.num == numerator)
      }
      edit { color.wrappedValue = Color(red: 0.25, green: 0.5, blue: 0.75, opacity: 0.4) }
      edit { view.addOutline(undoManager: undo) }
      let edited = document.workspace
      edit { view.addOutline(undoManager: undo) }
      #expect(document.workspace == edited)
      edit { view.removeOutline(at: 0, undoManager: undo) }
      #expect(document.workspace.definition.videoComponents[0].clock.outlines.count == 1)
      undo.undo()
      #expect(document.workspace == edited)
      #expect(width.wrappedValue.num == 7)
      #expect(
        Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: color.wrappedValue)
          == edited.definition.videoComponents[0].clock.outlines[0].extendedSrgbColor)
      undo.redo()
      edit { view.removeOutline(at: 0, undoManager: undo) }
      #expect(document.workspace.definition.videoComponents[0].clock.outlines.isEmpty)
      edit { view.removeOutline(at: 0, undoManager: undo) }
      edit { width.wrappedValue = .init() }
      #expect(document.workspace == original)
      edit { view.addOutline(undoManager: undo) }
      edit { width.wrappedValue = .with { $0.set(num: 9, den: 2) } }
      edit { color.wrappedValue = Color(red: 0.25, green: 0.5, blue: 0.75, opacity: 0.4) }
      let saved = document.workspace
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("ldtxworkspace")
      defer { try? FileManager.default.removeItem(at: url) }
      try await saveWorkspaceDocument(document, to: url)
      let loaded = try await loadWorkspaceDocument(at: url)
      #expect(loaded.workspace.definition == saved.definition)
      await loaded.shutdown()
      await document.shutdown()
    }

    @Test func hostedOutlineControls() async throws {
      let document = WorkspaceDocument(definition: .init(), preferences: .init())
      document.editWorkspace(undoManager: nil) {
        $0.definition.videoComponents = [WorkspaceResourceFactory.makeClock(id: 11, name: "Clock")]
      }
      let undo = UndoManager()
      undo.groupsByEvent = false
      let inspector = ClockInspector(
        stateService: document, appletData: WorkspaceAppletData(), internalID: 11)
      let hosting = NSHostingView(rootView: inspector.frame(width: 480, height: 1000))
      let window = ClockInspectorTestWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 1000),
        styleMask: .titled, backing: .buffered, defer: false)
      window.history = undo
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.contentView = hosting
      window.orderFront(nil)
      func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
      func capture(_ name: String) throws {
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: URL(fileURLWithPath: "/tmp/ldtx-clock-outline-\(name).png"))
      }
      func count() -> Int { document.workspace.definition.videoComponents[0].clock.outlines.count }
      await settleWorkspaceToolbar(window)
      try capture("empty")
      undo.beginUndoGrouping()
      inspector.addOutline(undoManager: undo)
      undo.endUndoGrouping()
      await settleWorkspaceToolbar(window)
      #expect(count() == 1)
      try capture("one")
      let field = try #require(
        views(hosting).compactMap { $0 as? NSTextField }
          .first { $0.isEditable && $0.stringValue == "1" })
      for text in ["0", "1.5", "3.5"] {
        undo.beginUndoGrouping()
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(
          text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertNewline(nil)
        undo.endUndoGrouping()
        await settleWorkspaceToolbar(window)
        #expect(
          document.workspace.definition.videoComponents[0].clock.outlines[0].thickness.double
            == Double(text))
      }
      let well = try #require(views(hosting).compactMap { $0 as? NSColorWell }.last)
      let color = NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 0.4)
      undo.beginUndoGrouping()
      well.color = color
      #expect(well.sendAction(well.action, to: well.target))
      undo.endUndoGrouping()
      await settleWorkspaceToolbar(window)
      #expect(
        document.workspace.definition.videoComponents[0].clock.outlines[0].extendedSrgbColor
          == Ldtx_Workspace_V4_Color(extendedSRGBNSColor: color))
      let editedColor = document.workspace.definition.videoComponents[0].clock.outlines[0]
        .extendedSrgbColor
      undo.undo()
      await settleWorkspaceToolbar(window)
      #expect(
        document.workspace.definition.videoComponents[0].clock.outlines[0].extendedSrgbColor
          != editedColor)
      undo.redo()
      await settleWorkspaceToolbar(window)
      #expect(
        document.workspace.definition.videoComponents[0].clock.outlines[0].extendedSrgbColor
          == editedColor)
      undo.beginUndoGrouping()
      inspector.addOutline(undoManager: undo)
      undo.endUndoGrouping()
      await settleWorkspaceToolbar(window)
      #expect(count() == 2)
      #expect(undo.canUndo)
      undo.undo()
      await settleWorkspaceToolbar(window)
      #expect(count() == 1)
      undo.redo()
      await settleWorkspaceToolbar(window)
      #expect(count() == 2)
      try capture("two-edited")
      document.isOutputActive = true
      await settleWorkspaceToolbar(window)
      #expect(
        views(hosting).compactMap { $0 as? NSTextField }.filter(\.isEditable)
          .allSatisfy { !$0.isEnabled })
      #expect(views(hosting).compactMap { $0 as? NSColorWell }.allSatisfy { !$0.isEnabled })
      try capture("output-disabled")
      document.isOutputActive = false
      await settleWorkspaceToolbar(window)
      #expect(views(hosting).compactMap { $0 as? NSColorWell }.allSatisfy { $0.isEnabled })

    }

    @Test func unavailableEditsAreIgnored() {
      let document = WorkspaceDocument(definition: .init(), preferences: .init())
      document.editWorkspace(undoManager: nil) {
        $0.definition.videoComponents = [WorkspaceResourceFactory.makeClock(id: 11, name: "Clock")]
      }
      let view = ClockInspector(
        stateService: document, appletData: WorkspaceAppletData(), internalID: 11)
      view.addOutline(undoManager: nil)
      let width = view.outlineBinding(at: 0, \.thickness, initial: .init(), undoManager: nil)
      let color = view.outlineColorBinding(at: 0, undoManager: nil)
      let before = document.workspace
      document.isOutputActive = true
      view.addOutline(undoManager: nil)
      view.removeOutline(at: 0, undoManager: nil)
      width.wrappedValue = .init()
      color.wrappedValue = .red
      #expect(document.workspace == before)
      document.isOutputActive = false
      document.isClosed = true
      view.addOutline(undoManager: nil)
      view.removeOutline(at: 0, undoManager: nil)
      width.wrappedValue = .init()
      color.wrappedValue = .red
      #expect(document.workspace == before)
      document.isClosed = false
      document.editWorkspace(undoManager: nil) { $0.definition.videoComponents.removeAll() }
      let removed = document.workspace
      view.addOutline(undoManager: nil)
      width.wrappedValue = .init()
      #expect(document.workspace == removed)
    }
  }
}

@MainActor
private final class ClockInspectorTestWindow: NSWindow {
  var history: UndoManager?
  override var undoManager: UndoManager? { history }
}
