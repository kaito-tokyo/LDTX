// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
import LDTXWorkspaceAppletModel
import LDTXYouTubeRTMPS
import SwiftUI

struct VideoComponentProgramLayers: View {
  @Environment(\.workspaceReportError) private var reportError
  let stateService: WorkspaceStateService
  let appletData: WorkspaceAppletData
  let componentID: Int64

  private var internalID: Int64? {
    guard
      let component = stateService.workspaceDefinition.videoComponents.first(where: {
        $0.internalID == componentID
      })
    else { return nil }
    return component.internalID
  }

  var body: some View {
    Section("Video Layers") {
      if let program = appletData.selectedProgram(
        in: stateService.workspaceDefinition, for: stateService.localStateURL)
      {
        LabeledContent("Program", value: program.displayName)
        Toggle("Landscape", isOn: membership(for: program.internalID, target: .landscape))
        Toggle("Portrait", isOn: membership(for: program.internalID, target: .portrait))
      } else {
        Text("No program selected").foregroundStyle(.secondary)
        Toggle("Landscape", isOn: .constant(false)).disabled(true)
        Toggle("Portrait", isOn: .constant(false)).disabled(true)
      }
    }
    .disabled(stateService.isOutputActive || internalID == nil)
  }

  func setIncluded(_ included: Bool, programID: Int64, target: WorkspaceCanvasTarget) throws {
    guard !stateService.isOutputActive,
      stateService.workspaceDefinition.programs.contains(where: { $0.internalID == programID }),
      internalID != nil
    else { throw WorkspaceSelectionError(message: "Video layer membership cannot be changed now.") }
    var ids =
      stateService.workspacePreferences[keyPath: target.preferences][programID]?
      .videoLayerInternalIds ?? []
    if included {
      guard !ids.contains(componentID) else { return }
      ids.append(componentID)
    } else {
      guard ids.contains(componentID) else { return }
      ids.removeAll { $0 == componentID }
    }
    stateService.workspacePreferences[keyPath: target.preferences][programID, default: .init()]
      .videoLayerInternalIds = ids
  }

  func membership(for programID: Int64, target: WorkspaceCanvasTarget) -> Binding<Bool> {
    Binding(
      get: {
        guard let id = internalID,
          let program = stateService.workspaceDefinition.programs.first(where: {
            $0.internalID == programID
          }
          )
        else { return false }
        return stateService.workspacePreferences[keyPath: target.preferences][program.internalID]?
          .videoLayerInternalIds.contains(id) ?? false
      },
      set: { value in
        do {
          guard internalID != nil,
            appletData.selectedProgram(
              in: stateService.workspaceDefinition, for: stateService.localStateURL)?.internalID
              == programID
          else {
            throw WorkspaceSelectionError(message: "The Program or Video Component is unavailable.")
          }
          try setIncluded(value, programID: programID, target: target)
        } catch { reportError(error) }
      })
  }
}

#if DEBUG
  #Preview("Video Layer Membership") {
    @Previewable @State var service = WorkspaceSidebarPreviewFixtures.makeUIState()
    Form {
      VideoComponentProgramLayers(
        stateService: service, appletData: WorkspaceAppletData(), componentID: 4)
    }
    .formStyle(.grouped)
    .frame(width: 320, height: 240)
    .onAppear {
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      program.displayName = "Studio"
      service.workspaceDefinition.programs = [program]
      service.workspacePreferences.landscapeProgramPreferences[100] = .with {
        $0.videoLayerInternalIds = [4]
      }
    }
  }
#endif
