// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
@testable import LDTXWorkspaceAppletController
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1026: Window-wide Submit", .serialized)
  @MainActor
  struct UCT1026WorkspaceWindowSubmitIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    private func makeStore() -> WorkspaceStoreService {
      let store = WorkspaceStoreService(definition: .init(), preferences: .init())
      store.workspaceDefinition.programs = [
        .with { $0.internalID = 100 }, .with { $0.internalID = 200 },
      ]
      store.workspaceDefinition.videoComponents = [.with { $0.vfxSource.internalID = 1 }]
      store.workspacePreferences.landscapeProgramPreferences[100] = .with {
        $0.videoLayerInternalIds = [1]
      }
      return store
    }

    @Test("Sidebar rejects valid and invalid drafts without validating or reporting errors")
    func sidebarRejectionNotifiesWithoutValidation() {
      let storeEditingState = WorkspaceEditingState()
      let store = makeStore()
      let original = WorkspaceInspectorSelector(kind: .workspacePrograms)
      store.inspectorSelector = original
      var dirty = true
      var notifications = 0
      var validations = 0
      var errors = 0
      storeEditingState.inputValidationErrorHandler = { _ in errors += 1 }
      storeEditingState.registerContentEditValidator(hasChanges: { dirty }) {
        validations += 1
        throw WorkspaceSelectionError(message: "Invalid draft")
      }
      WorkspaceSidebar.select(original, storeService: store, editingState: storeEditingState) {
        notifications += 1
      }
      #expect(notifications == 0)
      WorkspaceSidebar.select(
        .init(kind: .workspaceCanvas), storeService: store, editingState: storeEditingState
      ) {
        notifications += 1
      }
      #expect(store.inspectorSelector == original)
      #expect(notifications == 1 && validations == 0 && errors == 0)
      dirty = false
      WorkspaceSidebar.select(
        .init(kind: .workspaceCanvas), storeService: store, editingState: storeEditingState
      ) {
        notifications += 1
      }
      #expect(store.inspectorSelector == .init(kind: .workspaceCanvas))
      #expect(validations == 0 && errors == 0)
      dirty = true
      store.inspectorSelector = original
      #expect(store.inspectorSelector == original)
      #expect(notifications == 1)

    }

    @Test("All owners validate before any writes; invalid input is retained for retry")
    func validationStopsAllWritesAndAllowsRetry() throws {
      let storeAppletData = WorkspaceAppletData()
      let storeEditingState = WorkspaceEditingState()
      let store = makeStore()
      var modalErrors = 0
      let volumes = MasterVolumeEditor(
        storeService: store, appletData: storeAppletData, peakMeter: .init(),
        reportError: { _ in modalErrors += 1 }, editingState: storeEditingState)
      _ = volumes.view
      let layers = VideoLayersEditor(
        storeService: store, appletData: storeAppletData, editingState: storeEditingState,
        target: .landscape)
      _ = layers.view
      let row = try #require(layers.table.rows[1])
      let field = volumes.masterFields[0]
      field.stringValue = "-12"
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      row.state.edit("bad", at: 0)
      var errors: [String] = []
      storeEditingState.inputValidationErrorHandler = { errors.append($0.localizedDescription) }
      let original = store.workspacePreferences
      #expect(storeEditingState.hasUnconfirmedChanges)
      storeEditingState.submitPendingEdits(isOutputActive: store.isOutputActive)
      #expect(store.workspacePreferences == original)
      #expect(field.dirty && row.state.hasUnconfirmedChanges)
      #expect(field.stringValue == "-12" && row.state.strings[0] == "bad")
      #expect(storeEditingState.hasUnconfirmedChanges)
      #expect(errors.count == 1 && modalErrors == 0)
      row.state.edit("960", at: 0)
      storeEditingState.submitPendingEdits(isOutputActive: store.isOutputActive)
      #expect(!field.dirty && !row.state.hasUnconfirmedChanges)
      #expect(!storeEditingState.hasUnconfirmedChanges)
      let preferences = (store.workspacePreferences.landscapeProgramPreferences[100] ?? .init())
      #expect(preferences.audioMasterVolumeDecibels.double == -12)
      #expect(preferences.videoLayerTransforms[1]?.translationX.double == 0.5)
      storeEditingState.submitPendingEdits(isOutputActive: store.isOutputActive)
      #expect(!storeEditingState.hasUnconfirmedChanges)
    }

    @Test("Reverting input removes pending changes; ending text editing does not commit")
    func revertedInputsDoNotRequestSubmit() throws {
      let storeAppletData = WorkspaceAppletData()
      let storeEditingState = WorkspaceEditingState()
      let store = makeStore()
      let editor = MasterVolumeEditor(
        storeService: store, appletData: storeAppletData, peakMeter: .init(), reportError: { _ in },
        editingState: storeEditingState)
      _ = editor.view
      let field = editor.masterFields[0]
      let original = field.stringValue
      field.stringValue = "-6"
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      field.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification))
      #expect(field.dirty && storeEditingState.hasUnconfirmedChanges)
      #expect(
        !store.workspacePreferences.landscapeProgramPreferences[100]!.hasAudioMasterVolumeDecibels)
      field.stringValue = original
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      #expect(!storeEditingState.hasUnconfirmedChanges)
      storeEditingState.submitPendingEdits(isOutputActive: store.isOutputActive)
      #expect(!storeEditingState.hasUnconfirmedChanges)
      let layers = VideoLayersEditor(
        storeService: store, appletData: storeAppletData, editingState: storeEditingState,
        target: .landscape)
      _ = layers.view
      let row = try #require(layers.table.rows[1])
      let text = row.state.strings[0]
      row.state.edit("100", at: 0)
      #expect(storeEditingState.hasUnconfirmedChanges)
      row.state.edit(text, at: 0)
      #expect(!storeEditingState.hasUnconfirmedChanges)
    }

    @Test(
      "Pending edits block selection changes and editor replacement, but allow current selection")
    func pendingInputsBlockNavigation() throws {
      let storeAppletData = WorkspaceAppletData()
      let storeEditingState = WorkspaceEditingState()
      let store = makeStore()
      WorkspaceSidebar.select(
        .init(kind: .workspacePrograms), storeService: store, editingState: storeEditingState)
      let window = makeWorkspaceTestWindow(
        storeService: store, editingState: storeEditingState, dispatcher: ToolbarDispatcher(),
        appletData: storeAppletData)
      defer { window.close() }
      let editor = try #require(
        window.contentPane.children.first { $0 is MasterVolumeEditor } as? MasterVolumeEditor)
      let field = editor.masterFields[0]
      field.stringValue = "-6"
      field.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
      var errors = 0
      storeEditingState.inputValidationErrorHandler = { _ in errors += 1 }
      WorkspaceSidebar.select(
        .init(kind: .workspacePrograms), storeService: store, editingState: storeEditingState)
      #expect(errors == 0)
      WorkspaceSidebar.select(
        .init(kind: .workspaceCanvas), storeService: store, editingState: storeEditingState)
      #expect(store.inspectorSelector == .init(kind: .workspacePrograms))
      #expect(errors == 0)
      let dispatcher = ToolbarDispatcher()
      let inspector = WorkspaceProgramsInspector(
        storeService: store, editingState: storeEditingState, appletData: storeAppletData,
        runtimeActions: { dispatcher })
      #expect(throws: WorkspaceSelectionError.self) { try inspector.selectProgram(internalID: 200) }
      // Same Program is permitted (using a retained test dispatcher).
      try inspector.selectProgram(internalID: 100)
      let tabs = window.contentPane.testVideoTabs
      tabs.tabView.selectTabViewItem(at: 1)
      #expect(tabs.selectedTabViewItemIndex == 0)
      window.splitViewController.splitViewItems[2].isCollapsed = true
      #expect(field.dirty && field.stringValue == "-6")
      storeEditingState.submitPendingEdits(isOutputActive: store.isOutputActive)
      tabs.tabView.selectTabViewItem(at: 1)
      #expect(tabs.selectedTabViewItemIndex == 1)
    }

    @Test("Window consumes its own request; native items retain identity across state changes")
    func windowRequestsStayIndependent() async throws {
      let firstStoreEditingState = WorkspaceEditingState()
      let secondStoreEditingState = WorkspaceEditingState()
      let firstStore = makeStore()
      let secondStore = makeStore()
      let first = makeWorkspaceTestWindow(
        storeService: firstStore, editingState: firstStoreEditingState)
      let second = makeWorkspaceTestWindow(
        storeService: secondStore, editingState: secondStoreEditingState)
      defer {
        first.close()
        second.close()
      }
      await settleWorkspaceToolbar(first)
      let toolbar = try #require(first.toolbar)
      #expect(!toolbar.items.contains { $0.itemIdentifier.rawValue == "workspace.inspector.apply" })
      let separator = try #require(
        toolbar.items.first { $0.itemIdentifier == .inspectorTrackingSeparator })
      firstStoreEditingState.submitPendingEdits(isOutputActive: firstStore.isOutputActive)
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
      firstStore.isOutputActive = true
      await settleWorkspaceToolbar(first)
      firstStoreEditingState.submitPendingEdits(isOutputActive: firstStore.isOutputActive)
      #expect(firstStoreEditingState.hasUnconfirmedChanges)
      firstStore.isOutputActive = false
      await settleWorkspaceToolbar(first)
      try firstEditor.masterFields[0].submit()
      firstStoreEditingState.refreshUnconfirmedChanges()
      #expect(!firstStoreEditingState.hasUnconfirmedChanges)
      await settleWorkspaceToolbar(first)
      #expect(!firstStoreEditingState.hasUnconfirmedChanges)
      #expect(secondStoreEditingState.hasUnconfirmedChanges)
      #expect(
        (firstStore.workspacePreferences.landscapeProgramPreferences[100] ?? .init())
          .audioMasterVolumeDecibels.double
          == -6)
      #expect(
        !secondStore.workspacePreferences.landscapeProgramPreferences[100]!
          .hasAudioMasterVolumeDecibels)
      for collapsed in [true, false, true, false] {
        first.splitViewController.splitViewItems[2].isCollapsed = collapsed
        #expect(toolbar.items.last?.itemIdentifier.rawValue == "workspace.toggleInspector")
        #expect(
          !toolbar.items.contains { $0.itemIdentifier.rawValue == "workspace.inspector.apply" })
        #expect(
          toolbar.items.first { $0.itemIdentifier == .inspectorTrackingSeparator } === separator)
      }
    }
  }
}
