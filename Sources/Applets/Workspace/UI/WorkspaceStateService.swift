// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgramRuntime
import LDTXProtos
import LDTXWorkspaceAppletModel
import LDTXWorkspaceBundleFormat
import Observation

@MainActor
@Observable
public final class WorkspaceStateService {
  public var visionModels: [Int64: URL] = [:]
  public var workspaceDefinition: Ldtx_Workspace_V4_WorkspaceDefinitionV4
  public var workspaceOutputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4
  public var workspacePreferences: Ldtx_Workspace_V4_WorkspacePreferencesV4
  public var externalID: String?
  public var preferencesExternalID: String?
  public var outputSettingsExternalID: String?
  public var localStateURL: URL?

  public var selectedAudioMix: ProgramAudioPeakMeter.Master = .landscape

  public var inspectorSelector: WorkspaceInspectorSelector?
  public var isInspectorVisible = true
  public var isSidebarVisible = true

  public var minimumWindowWidth: CGFloat {
    480 + (isSidebarVisible ? 201 : 0) + (isInspectorVisible ? 241 : 0)
  }

  public var isClosed = false
  public var isInferring = false
  public var operationErrors: [NSError] = []

  public var isOutputActive = false
  public var recordingState: WorkspaceRecordingState = .idle
  public var isLocalRecording = false
  public var outputFailureMessage: String?
  public var visionResults: [Int64: String] = [:]
  public var visionFailureMessages: [Int64: String] = [:]
  public var modelPreparationGeneration: UInt64 = 0

  public var editingWorkspace: WorkspaceV4Bundle {
    WorkspaceV4Bundle(
      definitionExternalID: externalID, preferencesExternalID: preferencesExternalID,
      definition: workspaceDefinition, preferences: workspacePreferences,
      outputSettingsExternalID: outputSettingsExternalID,
      outputSettings: workspaceOutputSettings, visionModels: visionModels)
  }

  public func replaceEditingWorkspace(_ workspace: WorkspaceV4Bundle) {
    workspaceDefinition = workspace.definition
    workspacePreferences = workspace.preferences
    workspaceOutputSettings = workspace.outputSettings
    visionModels = workspace.visionModels
    externalID = workspace.definitionExternalID
    preferencesExternalID = workspace.preferencesExternalID
    outputSettingsExternalID = workspace.outputSettingsExternalID
  }

  public func setVisionModelURL(_ url: URL?, for visionID: Int64) {
    guard let index = workspaceDefinition.visions.firstIndex(where: { $0.internalID == visionID }),
      case .ldtxSceneDetectorVision(var vision) = workspaceDefinition.visions[index].vision
    else { return }
    if let url {
      guard visionModels[vision.modelInternalID] != url else { return }
      let resourceIDs = Set(workspaceDefinition.audioDevices.map(\.internalID))
        .union(workspaceDefinition.videoComponents.compactMap(\.internalID))
        .union(workspaceDefinition.visions.compactMap(\.internalID))
        .union(workspaceDefinition.programs.map(\.internalID))
      var id: Int64
      repeat {
        id = WorkspaceResourceFactory.nextInternalID()
      } while visionModels[id] != nil || resourceIDs.contains(id)
      visionModels[id] = url
      vision.modelInternalID = id
    } else {
      vision.modelInternalID = 0
    }
    workspaceDefinition.visions[index].vision = .ldtxSceneDetectorVision(vision)
  }

  public init(
    definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4 = .init(),
    preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4 = .init(),
    inspectorSelector: WorkspaceInspectorSelector? = nil,
    isOutputActive: Bool = false,
    isLocalRecording: Bool = false,
    outputFailureMessage: String? = nil,
    outputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4 = .init()
  ) {
    self.workspaceDefinition = definition
    self.workspaceOutputSettings = outputSettings
    self.workspacePreferences = preferences
    self.inspectorSelector = inspectorSelector
    self.isOutputActive = isOutputActive
    self.isLocalRecording = isLocalRecording
    self.outputFailureMessage = outputFailureMessage
  }
}
