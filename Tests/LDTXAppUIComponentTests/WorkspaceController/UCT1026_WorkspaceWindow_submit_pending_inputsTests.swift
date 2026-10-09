// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1026: Window-wide Submit", .serialized)
  @MainActor
  struct UCT1026WorkspaceWindowSubmitIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    private func makeStore() -> WorkspaceStoreService {
      let store = WorkspaceStoreService(definition: .init(), preferences: .init())
      store.definition.programs = [.with { $0.internalID = 100 }, .with { $0.internalID = 200 }]
      store.definition.videoComponents = [.with { $0.vfxSource.internalID = 1 }]
      store.preferences.landscapeProgramPreferences[100] = .with { $0.videoLayerInternalIds = [1] }
      return store
    }

    @Test("Input validation bypasses modal errors; runtime failures keep their handler")
    func validationErrorRouting() {
      let store = makeStore()
      var inputErrors = 0
      var runtimeErrors = 0
      store.inputValidationErrorHandler = { _ in inputErrors += 1 }
      store.errorHandler = { _ in runtimeErrors += 1 }
      store.reportError(WorkspaceSelectionError(message: "Invalid input"))
      store.reportError(RationalInputError.invalidNumber)
      #expect(inputErrors == 2 && runtimeErrors == 0)
      store.reportError(CocoaError(.fileWriteNoPermission))
      #expect(inputErrors == 2 && runtimeErrors == 1)
    }

    @Test("Sidebar rejects valid and invalid drafts without validating or reporting errors")
    func sidebarRejectionNotifiesWithoutValidation() {
      let store = makeStore()
      let original = WorkspaceInspectorSelector(kind: .workspacePrograms)
      store.inspectorSelector = original
      var dirty = true
      var notifications = 0
      var validations = 0
      var errors = 0
      store.pendingEditsDidBlockSelection = { notifications += 1 }
      store.errorHandler = { _ in errors += 1 }
      store.registerContentEditValidator(hasChanges: { dirty }) {
        validations += 1
        throw WorkspaceSelectionError(message: "Invalid draft")
      }
      store.inspectorSelector = original
      #expect(notifications == 0)
      store.inspectorSelector = .init(kind: .workspaceCanvas)
      #expect(store.inspectorSelector == original)
      #expect(notifications == 1 && validations == 0 && errors == 0)
      dirty = false
      store.inspectorSelector = .init(kind: .workspaceCanvas)
      #expect(store.inspectorSelector == .init(kind: .workspaceCanvas))
      #expect(validations == 0 && errors == 0)
    }

    @Test("All owners validate before any writes; invalid input is retained for retry")
    func validationStopsAllWritesAndAllowsRetry() throws {
      let store = makeStore()
      let volumes = MasterVolumeEditor(storeService: store)
      _ = volumes.view
      let layers = VideoLayersEditor(storeService: store, target: .landscape)
      _ = layers.view
      let row = try #require(layers.table.rows[1])
      let field = volumes.masterFields[0]
      field.stringValue = "-12"
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      row.state.edit("bad", at: 0)
      var errors: [String] = []
      store.inputValidationErrorHandler = { errors.append($0.localizedDescription) }
      var modalErrors = 0
      store.errorHandler = { _ in modalErrors += 1 }
      let original = store.preferences
      #expect(store.hasUnconfirmedChanges)
      store.hasPendingSubmit = true
      store.submitPendingEdits()
      #expect(store.preferences == original)
      #expect(field.dirty && row.state.hasUnconfirmedChanges)
      #expect(field.stringValue == "-12" && row.state.strings[0] == "bad")
      #expect(!store.hasPendingSubmit && store.hasUnconfirmedChanges)
      #expect(errors.count == 1 && modalErrors == 0)
      row.state.edit("960", at: 0)
      store.hasPendingSubmit = true
      store.submitPendingEdits()
      #expect(!field.dirty && !row.state.hasUnconfirmedChanges)
      #expect(!store.hasUnconfirmedChanges && !store.hasPendingSubmit)
      let preferences = try store.preferences(for: 100, target: .landscape)
      #expect(preferences.audioMasterVolumeDecibels.double == -12)
      #expect(preferences.videoLayerTransforms[1]?.translationX.double == 0.5)
      store.hasPendingSubmit = true
      #expect(!store.hasPendingSubmit)
    }

    @Test("Reverting input removes pending changes; ending text editing does not commit")
    func revertedInputsDoNotRequestSubmit() throws {
      let store = makeStore()
      let editor = MasterVolumeEditor(storeService: store)
      _ = editor.view
      let field = editor.masterFields[0]
      let original = field.stringValue
      field.stringValue = "-6"
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      field.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification))
      #expect(field.dirty && store.hasUnconfirmedChanges)
      #expect(!store.preferences.landscapeProgramPreferences[100]!.hasAudioMasterVolumeDecibels)
      field.stringValue = original
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      #expect(!store.hasUnconfirmedChanges)
      store.hasPendingSubmit = true
      #expect(!store.hasPendingSubmit)
      let layers = VideoLayersEditor(storeService: store, target: .landscape)
      _ = layers.view
      let row = try #require(layers.table.rows[1])
      let text = row.state.strings[0]
      row.state.edit("100", at: 0)
      #expect(store.hasUnconfirmedChanges)
      row.state.edit(text, at: 0)
      #expect(!store.hasUnconfirmedChanges)
    }

    @Test(
      "Pending edits block selection changes and editor replacement, but allow current selection")
    func pendingInputsBlockNavigation() throws {
      let store = makeStore()
      store.inspectorSelector = .init(kind: .workspacePrograms)
      let window = makeWorkspaceTestWindow(storeService: store, dispatcher: ToolbarDispatcher())
      defer { window.close() }
      let editor = try #require(
        window.contentPane.children.first { $0 is MasterVolumeEditor } as? MasterVolumeEditor)
      let field = editor.masterFields[0]
      field.stringValue = "-6"
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      var errors = 0
      store.errorHandler = { _ in errors += 1 }
      store.inspectorSelector = .init(kind: .workspacePrograms)
      #expect(errors == 0)
      store.inspectorSelector = .init(kind: .workspaceCanvas)
      #expect(store.inspectorSelector == .init(kind: .workspacePrograms))
      #expect(errors == 0)
      #expect(throws: WorkspaceSelectionError.self) { try store.selectProgram(internalID: 200) }
      // Same Program is permitted (using a retained test dispatcher).
      let dispatcher = ToolbarDispatcher()
      store.runtimeActions = dispatcher
      try store.selectProgram(internalID: 100)
      let tabs = window.contentPane.testVideoTabs
      tabs.tabView.selectTabViewItem(at: 1)
      #expect(tabs.selectedTabViewItemIndex == 0)
      window.splitViewController.splitViewItems[2].isCollapsed = true
      #expect(field.dirty && field.stringValue == "-6")
      store.hasPendingSubmit = true
      store.submitPendingEdits()
      tabs.tabView.selectTabViewItem(at: 1)
      #expect(tabs.selectedTabViewItemIndex == 1)
    }

    @Test("Window consumes its own request; native items retain identity across state changes")
    func windowRequestsStayIndependent() async throws {
      let firstStore = makeStore()
      let secondStore = makeStore()
      let first = makeWorkspaceTestWindow(storeService: firstStore)
      let second = makeWorkspaceTestWindow(storeService: secondStore)
      defer {
        first.close()
        second.close()
      }
      await settleWorkspaceToolbar(first)
      let toolbar = try #require(first.toolbar)
      let apply = try #require(
        toolbar.items.first { $0.itemIdentifier.rawValue == "workspace.inspector.apply" })
      let separator = try #require(
        toolbar.items.first { $0.itemIdentifier == .inspectorTrackingSeparator })
      #expect(!apply.isEnabled)
      firstStore.hasPendingSubmit = true
      #expect(!firstStore.hasPendingSubmit)
      let firstEditor = try #require(
        first.contentPane.children.first { $0 is MasterVolumeEditor } as? MasterVolumeEditor)
      let secondEditor = try #require(
        second.contentPane.children.first { $0 is MasterVolumeEditor } as? MasterVolumeEditor)
      for (field, value) in [
        (firstEditor.masterFields[0], "-6"), (secondEditor.masterFields[0], "-12"),
      ] {
        field.stringValue = value
        field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      }
      await settleWorkspaceToolbar(first)
      #expect(apply.isEnabled)
      firstStore.isOutputActive = true
      await settleWorkspaceToolbar(first)
      #expect(!apply.isEnabled)
      firstStore.hasPendingSubmit = true
      #expect(!firstStore.hasPendingSubmit)
      firstStore.isOutputActive = false
      await settleWorkspaceToolbar(first)
      try performWorkspaceToolbarAction(apply)
      #expect(firstStore.hasPendingSubmit && !apply.isEnabled)
      await settleWorkspaceToolbar(first)
      #expect(!firstStore.hasPendingSubmit && !firstStore.hasUnconfirmedChanges)
      #expect(secondStore.hasUnconfirmedChanges && !secondStore.hasPendingSubmit)
      #expect(
        try firstStore.preferences(for: 100, target: .landscape).audioMasterVolumeDecibels.double
          == -6)
      #expect(
        !secondStore.preferences.landscapeProgramPreferences[100]!.hasAudioMasterVolumeDecibels)
      for collapsed in [true, false, true, false] {
        first.splitViewController.splitViewItems[2].isCollapsed = collapsed
        #expect(apply.isHidden == collapsed)
        #expect(toolbar.items.last?.itemIdentifier.rawValue == "workspace.inspector")
        #expect(toolbar.items.first { $0.itemIdentifier == apply.itemIdentifier } === apply)
        #expect(
          toolbar.items.first { $0.itemIdentifier == .inspectorTrackingSeparator } === separator)
      }
    }
  }
}
