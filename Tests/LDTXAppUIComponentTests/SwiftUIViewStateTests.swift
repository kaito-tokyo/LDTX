// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

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

  @Test func programNameDialogRejectsEmptyUnchangedAndUnavailableNames() {
    let name = BindingState("  Camera  \n")
    let dialog = ProgramNameDialog(
      name: binding(to: name), title: "Rename Program", actionTitle: "Rename",
      currentName: "Current", isNameAvailable: { $0 != "Taken" }, submit: {}, cancel: {})

    #expect(dialog.trimmedName == "Camera")
    #expect(dialog.canSubmit)
    name.value = " Current "
    #expect(!dialog.canSubmit)
    name.value = " Taken "
    #expect(!dialog.canSubmit)
    name.value = " \n "
    #expect(!dialog.canSubmit)
    _ = dialog.body
  }

  @Test func workspaceSidebarUsesPreviewState() {
    let uiState = WorkspaceSidebarPreviewFixtures.makeUIState()
    let sidebar = WorkspaceSidebar(uiState: uiState)

    #expect(uiState.definition.displayName == "Workspace Sidebar Preview")
    _ = sidebar.body
  }

  @Test func workspaceUIStateTracksDefinitionAndPreferencesUntilSaved() {
    let workspace = WorkspaceUIState.cleanWorkspace(displayName: "State Test")
    let uiState = WorkspaceUIState(
      definition: workspace.definition, preferences: workspace.preferences)
    #expect(!uiState.isDirty)

    var definition = uiState.definition
    definition.displayName = "Edited Workspace"
    uiState.definition = definition
    #expect(uiState.isDirty)
    uiState.markSaved()
    #expect(!uiState.isDirty)

    var preferences = uiState.preferences
    preferences.monitorVolume = 0.5
    uiState.preferences = preferences
    #expect(uiState.isDirty)

    let validDefinition = uiState.definition
    var invalidDefinition = validDefinition
    invalidDefinition.canvasConfiguration.frameRate = 241
    #expect(throws: (any Error).self) {
      try uiState.replaceDefinition(invalidDefinition)
    }
    #expect(uiState.definition == validDefinition)
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
