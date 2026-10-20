// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
import LDTXYouTubeRTMPS
import SwiftUI

struct WorkspaceProgramSelector: View {
  let programs: [Ldtx_Workspace_V4_ProgramDefinition]
  @Binding var selection: Int64?

  var body: some View {
    if programs.isEmpty {
      Text("No Program").foregroundStyle(.secondary)
    } else {
      Picker("Program", selection: $selection) {
        ForEach(programs, id: \.internalID) {
          Text($0.displayName).tag(Optional($0.internalID))
        }
      }
      .pickerStyle(.radioGroup)
    }
  }
}

struct WorkspaceProgramsInspector: View {
  @Environment(\.undoManager) private var undoManager
  @Environment(\.workspaceReportError) private var reportError
  let stateService: WorkspaceDocument
  @Bindable var appletData: WorkspaceAppletData

  var runtimeActions: () -> (any WorkspaceRuntimeActions)? = { nil }

  private struct ActionTarget: Identifiable {
    let id: Int64
    let name: String
  }
  @State private var renameTarget: ActionTarget?
  @State private var nameDraft = ""
  @State private var deleteTarget: ActionTarget?
  @State private var showsDeleteConfirmation = false

  private var workspaceURL: URL? { stateService.localStateURL }

  var canSelectProgram: Bool {
    workspaceURL != nil && runtimeActions() != nil
      && stateService.recordingState.canSelectProgram
  }

  var body: some View {
    Form {
      WorkspaceProgramSelector(
        programs: stateService.workspaceDefinition.programs, selection: programSelection
      )
      .disabled(!canSelectProgram)
      ForEach(stateService.workspaceDefinition.programs, id: \.internalID) { program in
        HStack {
          Text(program.displayName)
          Spacer()
          Button("Rename…") {
            nameDraft = program.displayName
            renameTarget = ActionTarget(id: program.internalID, name: program.displayName)
          }
          Button("Delete…", role: .destructive) {
            deleteTarget = ActionTarget(id: program.internalID, name: program.displayName)
            showsDeleteConfirmation = true
          }
        }
        .disabled(stateService.isOutputActive)
      }
      Button("Add Program") { addProgram() }
        .disabled(stateService.isOutputActive)
    }
    .formStyle(.grouped)
    .sheet(item: $renameTarget) { target in
      ItemNameDialog(
        name: $nameDraft, title: "Rename Program", fieldTitle: "Name", submitTitle: "Rename",
        isNameAvailable: { name in
          var definition = stateService.workspaceDefinition
          definition.programs.removeAll { $0.internalID == target.id }
          return !WorkspaceResourceAddition.existingNames(definition).contains(name)
        },
        submit: { name in
          do {
            try renameProgram(internalID: target.id, name: name)
            renameTarget = nil
          } catch { reportError(error) }
        }, cancel: { renameTarget = nil })
    }
    .alert("Delete Program?", isPresented: $showsDeleteConfirmation, presenting: deleteTarget) {
      target in
      Button("Delete", role: .destructive) {
        do {
          guard let runtimeActions = runtimeActions() else {
            throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
          }
          try runtimeActions.removeProgram(internalID: target.id, undoManager: undoManager)
        } catch {
          reportError(error)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { target in
      Text("Delete “\(target.name)” and its saved preferences?")
    }
  }

  func renameProgram(internalID: Int64, name: String) throws {
    guard !stateService.isOutputActive else {
      throw WorkspaceSelectionError(message: "Programs cannot be edited during output.")
    }
    guard
      let index = stateService.workspaceDefinition.programs.firstIndex(where: {
        $0.internalID == internalID
      })
    else {
      throw WorkspaceSelectionError(message: "The Program is no longer available.")
    }
    let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var otherResources = stateService.workspaceDefinition
    otherResources.programs.remove(at: index)
    guard !candidate.isEmpty,
      !WorkspaceResourceAddition.existingNames(otherResources).contains(candidate)
    else {
      throw WorkspaceSelectionError(message: "Enter a unique, nonempty Program name.")
    }
    stateService.editWorkspace(undoManager: undoManager) { workspace in
      workspace.definition.programs[index].displayName = candidate
    }
    runtimeActions()?.updateProgramRuntimes()
  }

  private func addProgram() {
    let id = nextInternalID()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = id
    program.displayName = uniqueProgramDisplayName("Program")
    var definition = stateService.workspaceDefinition
    definition.programs.append(program)
    stateService.editWorkspace(undoManager: undoManager) { workspace in
      workspace.definition = definition
    }
    if let workspaceURL {
      var state = appletData.state(for: workspaceURL)
      if state.selectedProgramInternalID == nil {
        state.selectedProgramInternalID = id
        appletData.setState(state, for: workspaceURL)
        runtimeActions()?.updateProgramRuntimes()
      }
    }
  }
  private func nextInternalID() -> Int64 { WorkspaceResourceFactory.nextInternalID() }

  func uniqueProgramDisplayName(_ base: String) -> String {
    let names = WorkspaceResourceAddition.existingNames(stateService.workspaceDefinition)
    guard names.contains(base) else { return base }
    var suffix = 2
    while names.contains("\(base) \(suffix)") { suffix += 1 }
    return "\(base) \(suffix)"
  }

  func selectProgram(internalID: Int64) throws {
    guard let runtimeActions = runtimeActions() else {
      throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
    }
    try runtimeActions.selectProgram(internalID: internalID)
  }

  var programSelection: Binding<Int64?> {
    Binding(
      get: {
        let selectedID =
          workspaceURL.map { appletData.state(for: $0).selectedProgramInternalID } ?? nil
        return
          (stateService.workspaceDefinition.programs.first { $0.internalID == selectedID }
          ?? stateService.workspaceDefinition.programs.first)?.internalID
      },
      set: { id in
        guard let id, workspaceURL != nil else { return }
        do {
          try selectProgram(internalID: id)
        } catch { reportError(error) }
      })
  }
}
