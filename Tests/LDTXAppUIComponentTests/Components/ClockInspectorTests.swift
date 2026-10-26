// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("Clock Inspector outline editing", .serialized)
  @MainActor
  struct ClockInspectorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    private func outlines(in workspace: WorkspaceV4Bundle) -> [Ldtx_Workspace_V4_ClockTextOutline] {
      guard case .clock(let clock) = workspace.definition.videoComponents[0].videoComponent else {
        Issue.record("Missing clock")
        return []
      }
      return clock.outlines
    }

    @Test("LUB-1048: Repeated edits history and persistence")
    func repeatedEditsHistoryAndPersistence() async throws {
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
        #expect(width.wrappedValue?.num == Int32(numerator))
      }
      edit { color.wrappedValue = Color(red: 0.25, green: 0.5, blue: 0.75, opacity: 0.4) }
      edit { view.addOutline(undoManager: undo) }
      let edited = document.workspace
      edit { view.addOutline(undoManager: undo) }
      #expect(document.workspace == edited)
      edit { view.removeOutline(at: 0, undoManager: undo) }
      #expect(outlines(in: document.workspace).count == 1)
      undo.undo()
      #expect(document.workspace == edited)
      #expect(width.wrappedValue?.num == 7)
      #expect(
        Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: color.wrappedValue)
          == outlines(in: edited)[0].extendedSrgbColor)
      undo.redo()
      edit { view.removeOutline(at: 0, undoManager: undo) }
      #expect(outlines(in: document.workspace).isEmpty)
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

    @Test("LUB-1048: Hosted outline controls") func hostedOutlineControls() async throws {
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
      func count() -> Int { outlines(in: document.workspace).count }
      await settleWorkspaceToolbar(window)
      undo.beginUndoGrouping()
      inspector.addOutline(undoManager: undo)
      undo.endUndoGrouping()
      await settleWorkspaceToolbar(window)
      #expect(count() == 1)
      let field = try #require(
        views(hosting).compactMap { $0 as? NSTextField }
          .first { $0.isEditable && $0.stringValue == "1" })
      for text in ["0", "1.5", "3.5"] {
        undo.beginUndoGrouping()
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(
          text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        undo.endUndoGrouping()
        #expect(window.firstResponder === editor)
        #expect(
          outlines(in: document.workspace)[0].thickness?.double
            == Double(text))
      }
      let editor = try #require(field.currentEditor() as? NSTextView)
      let snapshot = try await document.snapshot(
        contentType: WorkspaceDocument.writableContentTypes[0])
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("ldtxworkspace")
      defer { try? FileManager.default.removeItem(at: url) }
      try WorkspaceBundleWriterV4().write(snapshot, to: url)
      let loaded = try WorkspaceBundleReaderV4(at: url).read()
      #expect(window.firstResponder === editor)
      #expect(
        outlines(in: loaded)[0].thickness?.double == 3.5
      )
      undo.undo()
      await settleWorkspaceToolbar(window)
      #expect(
        outlines(in: document.workspace)[0].thickness?.double == 1.5)
      #expect(editor.string == "1.5")
      undo.redo()
      await settleWorkspaceToolbar(window)
      #expect(
        outlines(in: document.workspace)[0].thickness?.double == 3.5)
      #expect(editor.string == "3.5")
      let well = try #require(views(hosting).compactMap { $0 as? NSColorWell }.last)
      let color = NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 0.4)
      undo.beginUndoGrouping()
      well.color = color
      #expect(well.sendAction(well.action, to: well.target))
      undo.endUndoGrouping()
      await settleWorkspaceToolbar(window)
      #expect(
        outlines(in: document.workspace)[0].extendedSrgbColor
          == Ldtx_Workspace_V4_Color(extendedSRGBNSColor: color))
      let editedColor = outlines(in: document.workspace)[0]
        .extendedSrgbColor
      undo.undo()
      await settleWorkspaceToolbar(window)
      #expect(
        outlines(in: document.workspace)[0].extendedSrgbColor
          != editedColor)
      undo.redo()
      await settleWorkspaceToolbar(window)
      #expect(
        outlines(in: document.workspace)[0].extendedSrgbColor
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
      document.isOutputActive = true
      await settleWorkspaceToolbar(window)
      #expect(
        views(hosting).compactMap { $0 as? NSTextField }.filter(\.isEditable)
          .allSatisfy { !$0.isEnabled })
      #expect(views(hosting).compactMap { $0 as? NSColorWell }.allSatisfy { !$0.isEnabled })
      document.isOutputActive = false
      await settleWorkspaceToolbar(window)
      #expect(views(hosting).compactMap { $0 as? NSColorWell }.allSatisfy { $0.isEnabled })

    }

    struct OutlineWidthInput: Sendable, Codable {
      let saved: Int32
      let input: String
      let expected: Double
    }

    @Test(
      "LUB-1048: Outline width input preserves invalid drafts and commits supported values",
      arguments: [
        OutlineWidthInput(saved: 1, input: "3", expected: 3),
        OutlineWidthInput(saved: 3, input: "3.", expected: 3),
        OutlineWidthInput(saved: 1, input: "3.5", expected: 3.5),
        OutlineWidthInput(saved: 1, input: "0", expected: 0),
        OutlineWidthInput(saved: 1, input: "64", expected: 64),
        OutlineWidthInput(saved: 1, input: "65", expected: 1),
        OutlineWidthInput(saved: 1, input: "100", expected: 1),
        OutlineWidthInput(saved: 1, input: "-1", expected: 1),
        OutlineWidthInput(saved: 1, input: "1/0", expected: 1),
        OutlineWidthInput(saved: 1, input: "2147483648", expected: 1),
        OutlineWidthInput(saved: 1, input: "", expected: 1),
        OutlineWidthInput(saved: 100, input: "65", expected: 100),
        OutlineWidthInput(saved: 100, input: "64", expected: 64),
      ])
    func outlineWidthInput(_ data: OutlineWidthInput) async throws {
      let document = WorkspaceDocument(definition: .init(), preferences: .init())
      document.editWorkspace(undoManager: nil) {
        $0.definition.videoComponents = [WorkspaceResourceFactory.makeClock(id: 11, name: "Clock")]
        guard case .clock(var clock) = $0.definition.videoComponents[0].videoComponent else {
          Issue.record("Missing clock")
          return
        }
        clock.outlines = [
          .with { $0.thickness = .with { $0.set(num: data.saved, den: 1) } }
        ]
        $0.definition.videoComponents[0].videoComponent = .clock(clock)
      }
      let undo = UndoManager()
      undo.groupsByEvent = false
      let hosting = NSHostingView(
        rootView: ClockInspector(
          stateService: document, appletData: WorkspaceAppletData(), internalID: 11
        ).frame(width: 480, height: 1000))
      let window = ClockInspectorTestWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 1000),
        styleMask: .titled, backing: .buffered, defer: false)
      window.history = undo
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.contentView = hosting
      window.orderFront(nil)
      await settleWorkspaceToolbar(window)
      #expect(
        outlines(in: document.workspace)[0].thickness?.num
          == data.saved)
      #expect(!undo.canUndo)
      func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
      }
      let field = try #require(
        fields(hosting).first { $0.isEditable && $0.stringValue == String(data.saved) })
      #expect(window.makeFirstResponder(field))
      let editor = try #require(field.currentEditor() as? NSTextView)
      undo.beginUndoGrouping()
      editor.insertText(
        data.input, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
      undo.endUndoGrouping()
      await settleWorkspaceToolbar(window)
      #expect(editor.string == data.input)
      #expect(
        outlines(in: document.workspace)[0].thickness?.double
          == data.expected)
      let snapshot = try await document.snapshot(
        contentType: WorkspaceDocument.writableContentTypes[0])
      #expect(snapshot == document.workspace)
    }

    struct OutlineMembership: Sendable, Codable {
      let secondWidth: Int32
      let removedIndex: Int
    }

    @Test(
      "LUB-1048: Membership changes reset drafts and focus",
      arguments: [
        OutlineMembership(secondWidth: 1, removedIndex: 0),
        OutlineMembership(secondWidth: 1, removedIndex: 1),
        OutlineMembership(secondWidth: 2, removedIndex: 0),
        OutlineMembership(secondWidth: 2, removedIndex: 1),
      ])
    func membershipChangesResetDraftsAndFocus(_ data: OutlineMembership) async throws {
      let secondWidth = data.secondWidth
      let removedIndex = data.removedIndex
      let document = WorkspaceDocument(definition: .init(), preferences: .init())
      document.editWorkspace(undoManager: nil) {
        $0.definition.videoComponents = [WorkspaceResourceFactory.makeClock(id: 11, name: "Clock")]
        guard case .clock(var clock) = $0.definition.videoComponents[0].videoComponent else {
          Issue.record("Missing clock")
          return
        }
        clock.outlines = [1, secondWidth].map { width in
          .with { $0.thickness = .with { $0.set(num: width, den: 1) } }
        }
        $0.definition.videoComponents[0].videoComponent = .clock(clock)
      }
      let inspector = ClockInspector(
        stateService: document, appletData: WorkspaceAppletData(), internalID: 11)
      let undo = UndoManager()
      undo.groupsByEvent = false
      let hosting = NSHostingView(rootView: inspector.frame(width: 480, height: 1000))
      let window = ClockInspectorTestWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 1000),
        styleMask: .titled, backing: .buffered, defer: false)
      window.history = undo
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.contentView = hosting
      window.orderFront(nil)
      await settleWorkspaceToolbar(window)
      func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
      }
      func widths() -> [Int32] {
        outlines(in: document.workspace).compactMap { $0.thickness?.num }
      }
      func displayedWidths() -> [String] {
        fields(hosting).filter {
          $0.isEditable && $0.stringValue != "Clock" && $0.stringValue != "48"
        }.map(\.stringValue)
      }
      func invalidDraft() async throws -> (NSTextField, NSTextView) {
        let field = try #require(
          fields(hosting).first {
            $0.isEditable && $0.stringValue == String(widths()[0])
          })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        // Isolate structural document history from native text-draft history.
        undo.disableUndoRegistration()
        editor.insertText(
          "65", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        undo.enableUndoRegistration()
        await settleWorkspaceToolbar(window)
        #expect(editor.string == "65")
        return (field, editor)
      }
      func expectReset(_ old: (NSTextField, NSTextView), expected: [Int32]) {
        #expect(!old.0.isDescendant(of: hosting))
        #expect(window.firstResponder !== old.1)
        #expect(widths() == expected)
        #expect(displayedWidths() == expected.map(String.init))
      }
      let original: [Int32] = [1, secondWidth]
      let remaining: [Int32] = [removedIndex == 0 ? secondWidth : 1]
      let removedDraft = try await invalidDraft()
      undo.beginUndoGrouping()
      inspector.removeOutline(at: removedIndex, undoManager: undo)
      undo.endUndoGrouping()
      await settleWorkspaceToolbar(window)
      expectReset(removedDraft, expected: remaining)
      let undoDraft = try await invalidDraft()
      undo.undo()
      await settleWorkspaceToolbar(window)
      expectReset(undoDraft, expected: original)
      let redoDraft = try await invalidDraft()
      undo.redo()
      await settleWorkspaceToolbar(window)
      expectReset(redoDraft, expected: remaining)
      let addedDraft = try await invalidDraft()
      undo.beginUndoGrouping()
      inspector.addOutline(undoManager: undo)
      undo.endUndoGrouping()
      await settleWorkspaceToolbar(window)
      expectReset(addedDraft, expected: remaining + [1])
      let undoAddDraft = try await invalidDraft()
      undo.undo()
      await settleWorkspaceToolbar(window)
      expectReset(undoAddDraft, expected: remaining)
      let redoAddDraft = try await invalidDraft()
      undo.redo()
      await settleWorkspaceToolbar(window)
      expectReset(redoAddDraft, expected: remaining + [1])
    }

    struct OutlineEditState: Sendable, Codable {
      let outputActive: Bool
      let closed: Bool
      let componentPresent: Bool
    }

    @Test(
      "LUB-1048: Unavailable outline edits preserve document content",
      arguments: [
        OutlineEditState(outputActive: true, closed: false, componentPresent: true),
        OutlineEditState(outputActive: false, closed: true, componentPresent: true),
        OutlineEditState(outputActive: false, closed: false, componentPresent: false),
      ])
    func unavailableEdits(_ data: OutlineEditState) {
      let document = WorkspaceDocument(definition: .init(), preferences: .init())
      document.editWorkspace(undoManager: nil) {
        $0.definition.videoComponents = [WorkspaceResourceFactory.makeClock(id: 11, name: "Clock")]
      }
      let view = ClockInspector(
        stateService: document, appletData: WorkspaceAppletData(), internalID: 11)
      view.addOutline(undoManager: nil)
      let width = view.outlineBinding(at: 0, \.thickness, initial: .init(), undoManager: nil)
      let color = view.outlineColorBinding(at: 0, undoManager: nil)
      document.isOutputActive = data.outputActive
      document.isClosed = data.closed
      if !data.componentPresent {
        document.editWorkspace(undoManager: nil) { $0.definition.videoComponents.removeAll() }
      }
      let before = document.workspace
      view.addOutline(undoManager: nil)
      view.removeOutline(at: 0, undoManager: nil)
      width.wrappedValue = .init()
      color.wrappedValue = .red
      #expect(document.workspace == before)
    }

  }
}

@MainActor
private final class ClockInspectorTestWindow: NSWindow {
  var history: UndoManager?
  override var undoManager: UndoManager? { history }
}
