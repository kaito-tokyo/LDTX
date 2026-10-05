// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import Testing

@Suite struct WorkspaceSelectionUnitTestSuite {
  @Test func discoveryFailureBlocksSelectionButAllowsClearing() {
    #expect(
      WorkspaceSelectionRules.canSubmit(
        nil as Int?, availableIDs: [], isEditable: true, loadError: "Discovery failed"))
    #expect(
      !WorkspaceSelectionRules.canSubmit(
        1, availableIDs: [1], isEditable: true, loadError: "Discovery failed"))
    #expect(
      !WorkspaceSelectionRules.canSubmit(
        nil as Int?, availableIDs: [], isEditable: false, loadError: "Discovery failed"))
    #expect(
      !WorkspaceSelectionRules.canSubmit(
        2, availableIDs: [1], isEditable: true, loadError: nil))
    #expect(
      WorkspaceSelectionRules.canSubmit(
        1, availableIDs: [1], isEditable: true, loadError: nil))
  }

  @Test func programSwitchingPermitsRunningButRejectsTransitions() {
    for state: WorkspaceRecordingState in [.idle, .paused, .recording, .failed("error")] {
      #expect(state.canSelectProgram)
    }
    for state: WorkspaceRecordingState in [.starting, .pausing, .stopping] {
      #expect(!state.canSelectProgram)
    }
    let options = [
      WorkspaceSelectionOption(id: UInt64(1), name: "Same"),
      WorkspaceSelectionOption(id: UInt64(2), name: "Same"),
    ]
    #expect(options.map(\.id) == [1, 2])
    #expect(
      WorkspaceSelectionRules.reconciled(nil as UInt64?, availableIDs: options.map(\.id)) == nil)
  }

  @Test func dynamicCandidatesNeverSelectThemselves() {
    #expect(WorkspaceSelectionRules.reconciled(nil as Int?, availableIDs: []) == nil)
    #expect(WorkspaceSelectionRules.reconciled(nil as Int?, availableIDs: [1, 2]) == nil)
    #expect(WorkspaceSelectionRules.reconciled(1, availableIDs: [1, 2]) == 1)
    #expect(WorkspaceSelectionRules.reconciled(1, availableIDs: [2]) == nil)
  }

  @Test func restoredValueCanBeDisplayedBeforeAndAfterDiscovery() {
    let options = [WorkspaceSelectionOption(id: 1, name: "Camera")]
    #expect(
      WorkspaceSelectionRules.displayName(selection: 1, options: [], loaded: false) == "Checking…")
    #expect(
      WorkspaceSelectionRules.displayName(selection: 1, options: options, loaded: true) == "Camera")
    #expect(
      WorkspaceSelectionRules.displayName(selection: 2, options: options, loaded: true)
        == "Unavailable")
    #expect(
      WorkspaceSelectionRules.displayName(selection: nil, options: options, loaded: true)
        == "Unassigned")
  }

  @Test @MainActor func resourceDraftsAndSidebarStartUnselected() {
    let draft = WorkspaceAddDraft()
    #expect(draft.physicalDeviceID == nil)
    #expect(draft.videoComponentID == nil)
    let state = WorkspaceUIState(definition: .init(), preferences: .init())
    #expect(state.inspectorSelector == nil)
    let before = state.definition
    #expect(
      WorkspaceResourceAddition.validationMessage(
        sheet: .device, draft: draft, devices: [], uiState: state) != nil)
    #expect(
      WorkspaceResourceAddition.validationMessage(
        sheet: .vision, draft: draft, devices: [], uiState: state) != nil)
    #expect(state.definition == before)
  }
}
