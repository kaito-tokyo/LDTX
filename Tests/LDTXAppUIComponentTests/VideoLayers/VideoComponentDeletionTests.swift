// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Testing

extension AppUIComponentTestSuite {
  @Suite @MainActor
  struct VideoComponentDeletionIntegrationTestSuite {
    @Test func deletionClearsReferencesAcrossProgramsAndPreservesOtherContent() throws {
      let state = WorkspaceStateService()
      state.workspaceDefinition.programs = [100, 200].map { id in
        .with { $0.internalID = Int64(id); $0.displayName = "Program \(id)" }
      }
      state.workspaceDefinition.videoComponents = [10, 20].map { id in
        .with {
          $0.vfxSource.internalID = Int64(id)
          $0.vfxSource.displayName = "Source \(id)"
          $0.vfxSource.deviceWidth = 1920
          $0.vfxSource.deviceHeight = 1080
        }
      }
      state.workspaceDefinition.canvasConfiguration.ptsMasterVfxSourceInternalID = 10
      state.workspaceDefinition.visions = [
        .with { $0.ocrVision.internalID = 30; $0.ocrVision.displayName = "OCR"
          $0.ocrVision.videoComponentInternalID = 20 },
        .with { $0.ldtxSceneDetectorVision.internalID = 40
          $0.ldtxSceneDetectorVision.displayName = "Scene"
          $0.ldtxSceneDetectorVision.videoComponentInternalID = 20 },
        .with { $0.ocrVision.internalID = 50; $0.ocrVision.displayName = "Other OCR"
          $0.ocrVision.videoComponentInternalID = 20 },
      ]
      let program = Ldtx_Workspace_V4_ProgramPreferences.with {
        $0.videoLayerInternalIds = [10, 20, 10]
        $0.videoLayerTransforms = [10: .init(), 20: .init()]
        $0.videoLayerHidden = [10: true, 20: false]
        $0.audioMasterVolumeDecibels.set(num: -30, den: 10)
      }
      for id: Int64 in [100, 200] {
        state.workspacePreferences.landscapeProgramPreferences[id] = program
        state.workspacePreferences.portraitProgramPreferences[id] = program
      }
      state.inspectorSelector = .init(kind: .vfxVideoComponent, internalID: 10)
      let original = state.editingWorkspace
      VideoComponentDeletion.delete(10, from: state)
      #expect(state.workspaceDefinition.videoComponents.compactMap(\.internalID) == [20])
      #expect(!state.workspaceDefinition.canvasConfiguration.hasPtsMasterVfxSourceInternalID)
      #expect(state.workspaceDefinition.visions == original.definition.visions)
      #expect(state.inspectorSelector == nil)
      for preferences in [state.workspacePreferences.landscapeProgramPreferences,
        state.workspacePreferences.portraitProgramPreferences] {
        for id: Int64 in [100, 200] {
          let value = try #require(preferences[id])
          #expect(value.videoLayerInternalIds == [20])
          #expect(value.videoLayerTransforms == [20: .init()])
          #expect(value.videoLayerHidden == [20: false])
          #expect(value.audioMasterVolumeDecibels == program.audioMasterVolumeDecibels)
        }
      }
      #expect(WorkspaceBundleValidatorV4.validationIssues(in: state.workspaceDefinition,
        preferences: state.workspacePreferences).isEmpty)
      // Document Undo restores this same complete editing snapshot.
      state.replaceEditingWorkspace(original)
      #expect(state.editingWorkspace == original)
    }

    @Test func activeOutputClosedAndMissingTargetsDoNotChangeContent() {
      let state = WorkspaceStateService()
      state.workspaceDefinition.videoComponents = [WorkspaceResourceFactory.makeSolidColor(id: 10, name: "Color")]
      let original = state.editingWorkspace
      state.isOutputActive = true
      VideoComponentDeletion.delete(10, from: state)
      #expect(state.editingWorkspace == original)
      state.isOutputActive = false
      state.isClosed = true
      VideoComponentDeletion.delete(10, from: state)
      #expect(state.editingWorkspace == original)
      state.isClosed = false
      VideoComponentDeletion.delete(999, from: state)
      #expect(state.editingWorkspace == original)
    }

    @Test func visionInputsMustBeReassignedBeforeDeletion() {
      for sceneDetector in [false, true] {
        let state = WorkspaceStateService()
        state.workspaceDefinition.videoComponents = [.with { $0.vfxSource.internalID = 10 }]
        state.workspaceDefinition.visions = [.with {
          if sceneDetector {
            $0.ldtxSceneDetectorVision.internalID = 30
            $0.ldtxSceneDetectorVision.videoComponentInternalID = 10
          } else {
            $0.ocrVision.internalID = 30
            $0.ocrVision.videoComponentInternalID = 10
          }
        }]
        let original = state.editingWorkspace
        #expect(VideoComponentDeletion.hasVisionInputReference(10, in: state))
        VideoComponentDeletion.delete(10, from: state)
        #expect(state.editingWorkspace == original)
      }
    }
  }
}
