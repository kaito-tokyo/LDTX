// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct VideoComponentProgramLayers: View {
  let storeService: WorkspaceStoreService
  let componentID: WorkspaceStoreService.VideoComponentWrapper.ID
  @State private var errorMessage: String?

  private var internalID: UInt64? {
    guard
      let component = storeService.definition.videoComponents.first(where: { $0.id == componentID })
    else { return nil }
    return try? WorkspaceV4IntegrityValidator.videoComponentID(component)
  }

  var body: some View {
    Section("Video Layers") {
      if let program = storeService.selectedProgram {
        LabeledContent("Program", value: program.displayName)
        Toggle("Landscape", isOn: membership(for: program.internalID, target: .landscape))
        Toggle("Portrait", isOn: membership(for: program.internalID, target: .portrait))
      } else {
        Text("No program selected").foregroundStyle(.secondary)
        Toggle("Landscape", isOn: .constant(false)).disabled(true)
        Toggle("Portrait", isOn: .constant(false)).disabled(true)
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
    }
    .disabled(storeService.isOutputActive || internalID == nil)
    .onChange(of: storeService.selectedProgram?.internalID) { errorMessage = nil }
  }

  func membership(for programID: UInt64, target: WorkspaceCanvasTarget) -> Binding<Bool> {
    Binding(
      get: {
        guard let id = internalID,
          let program = storeService.definition.programs.first(where: { $0.internalID == programID }
          )
        else { return false }
        return program[keyPath: target.layerIDs].contains(id)
      },
      set: { value in
        do {
          guard let id = internalID,
            storeService.selectedProgram?.internalID == programID
          else {
            throw WorkspaceSelectionError(message: "The Program or Video Component is unavailable.")
          }
          try storeService.setVideoLayerIncluded(
            value, componentID: id, programID: programID, target: target)
          errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
      })
  }
}

#if DEBUG
  #Preview("Video Layer Membership") {
    @Previewable @State var service = WorkspaceSidebarPreviewFixtures.makeUIState()
    Form {
      VideoComponentProgramLayers(storeService: service, componentID: .solidColorFill(4))
    }
    .formStyle(.grouped)
    .frame(width: 320, height: 240)
    .onAppear {
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      program.displayName = "Studio"
      program.landscapeVideoLayerInternalIds = [4]
      service.definition.programs = [program]
    }
  }
#endif
