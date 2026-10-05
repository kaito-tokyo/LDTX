// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXDeviceRegistry
import LDTXProgram
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

@Suite
@MainActor
struct SwiftUIViewStateUnitTestSuite {
  @Test func itemNameDialogNormalizesCandidateAndValidatesAvailability() {
    let name = BindingState("  Camera  \n")
    let dialog = ItemNameDialog(
      name: binding(to: name), title: "Add Input", fieldTitle: "Name",
      isNameAvailable: { $0 != "Taken" }, submit: { _ in }, cancel: {})

    #expect(dialog.candidate == "Camera")
    #expect(dialog.canSubmit)
    name.value = " Taken \n"
    #expect(dialog.candidate == "Taken")
    #expect(!dialog.canSubmit)
    name.value = " \n  "
    #expect(dialog.candidate.isEmpty)
    #expect(!dialog.canSubmit)
    _ = dialog.body
  }

  @Test func workspaceSidebarUsesPreviewState() {
    let uiState = WorkspaceSidebarPreviewFixtures.makeUIState()
    let sidebar = WorkspaceSidebar(
      uiState: uiState, deviceRegistry: DeviceRegistryService(), appletData: WorkspaceAppletData())

    #expect(uiState.definition.displayName == "Workspace Sidebar Preview")
    _ = sidebar.body
  }

  @Test(arguments: [WorkspaceAddSheet.device, .videoComponent, .vision])
  func workspaceSidebarRejectsAdditionWithoutLiveDocument(sheet: WorkspaceAddSheet) {
    let uiState = WorkspaceSidebarPreviewFixtures.makeUIState()
    let definition = uiState.definition
    let selection = uiState.inspectorSelector
    let data = WorkspaceAppletData()
    let assignments = data.physicalDeviceIDsByResourceInternalID
    let sidebar = WorkspaceSidebar(
      uiState: uiState, deviceRegistry: DeviceRegistryService(), appletData: data)
    var draft = WorkspaceAddDraft()
    draft.name = "New component"
    draft.componentKind = .solidColor

    #expect(!sidebar.canAddResource)
    do {
      try sidebar.addResource(sheet, draft: draft)
      Issue.record("Addition must require a live document")
    } catch {
      #expect(error.localizedDescription == "The Workspace document is unavailable.")
    }
    #expect(uiState.definition == definition)
    #expect(uiState.inspectorSelector == selection)
    #expect(data.physicalDeviceIDsByResourceInternalID == assignments)
  }

  private func binding<Value>(to state: BindingState<Value>) -> Binding<Value> {
    Binding(get: { state.value }, set: { state.value = $0 })
  }

  private final class BindingState<Value> {
    var value: Value

    init(_ value: Value) {
      self.value = value
    }
  }
}
