// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXProtos
import LDTXWorkspaceAppletInterface
import SwiftUI

struct WorkspaceProgramSelector: View {
  let programs: [Ldtx_Workspace_V4_ProgramDefinition]
  @Binding var selection: UInt64?

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
  @Environment(\.documentReference) private var documentReference
  @Environment(\.workspaceDispatcher) private var dispatcher
  let uiState: WorkspaceUIState
  @Bindable var appletData: WorkspaceAppletData
  @State private var errorMessage: String?

  private var workspaceURL: URL? {
    guard let document = documentReference?.document else { return nil }
    return document.fileURL ?? uiState.localStateURL
  }

  var canSelectProgram: Bool { workspaceURL != nil && uiState.recordingState.canSelectProgram }

  var body: some View {
    Form {
      WorkspaceProgramSelector(programs: uiState.definition.programs, selection: programSelection)
        .disabled(!canSelectProgram)
      Button("Add Program") { addProgram() }
        .disabled(uiState.isOutputActive)
      if let errorMessage {
        Text(errorMessage).foregroundStyle(.red)
      }
    }
    .formStyle(.grouped)
  }

  private func addProgram() {
    let id = nextInternalID()
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = id
    program.displayName = uniqueProgramDisplayName("Program")
    var definition = uiState.definition
    definition.programs.append(program)
    uiState.definition = definition
    if let workspaceURL {
      var state = appletData.state(for: workspaceURL)
      if state.selectedProgramInternalID == nil {
        state.selectedProgramInternalID = id
        appletData.setState(state, for: workspaceURL)
        dispatcher?.updateProgramRuntimes()
      }
    }
    errorMessage = nil
    dispatcher?.synchronizeAudioMonitor()
  }
  private func nextInternalID() -> UInt64 { WorkspaceResourceFactory.nextInternalID() }

  private func uniqueProgramDisplayName(_ base: String) -> String {
    let names = Set(uiState.definition.programs.map(\.displayName))
    guard names.contains(base) else { return base }
    var suffix = 2
    while names.contains("\(base) \(suffix)") { suffix += 1 }
    return "\(base) \(suffix)"
  }

  var programSelection: Binding<UInt64?> {
    Binding(
      get: {
        let selectedID =
          workspaceURL.map { appletData.state(for: $0).selectedProgramInternalID } ?? nil
        return
          (uiState.definition.programs.first { $0.internalID == selectedID }
          ?? uiState.definition.programs.first)?.internalID
      },
      set: { id in
        guard let id, workspaceURL != nil else { return }
        do {
          guard let dispatcher else {
            throw WorkspaceSelectionError(message: "Program selection is unavailable.")
          }
          try dispatcher.selectProgram(internalID: id)
          errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
      })
  }
}
