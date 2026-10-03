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

  var body: some View {
    Form {
      WorkspaceProgramSelector(programs: uiState.definition.programs, selection: programSelection)
        .disabled(!uiState.recordingState.canSelectProgram)
      if let errorMessage {
        Text(errorMessage).foregroundStyle(.red)
      }
    }
    .formStyle(.grouped)
  }

  var programSelection: Binding<UInt64?> {
    Binding(
      get: {
        let url = documentReference?.document?.fileURL ?? uiState.localStateURL
        let selectedID = url.map { appletData.state(for: $0).selectedProgramInternalID } ?? nil
        return
          (uiState.definition.programs.first { $0.internalID == selectedID }
          ?? uiState.definition.programs.first)?.internalID
      },
      set: { id in
        guard let id else { return }
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
