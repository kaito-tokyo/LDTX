// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletInterface
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1010: change-canvas-membership", .serialized)
  @MainActor
  struct UCT1010VideoComponentProgramLayersIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }
    @Test(
      "UCT-1010.1: Component inspector membership uses latest program and preserves preferences")
    func componentInspectorMembershipUsesLatestProgramAndPreservesPreferences() throws {
      let service = WorkspaceStoreService(definition: .init(), preferences: .init())
      var first = Ldtx_Workspace_V4_ProgramDefinition()
      first.internalID = 100
      var second = Ldtx_Workspace_V4_ProgramDefinition()
      second.internalID = 200
      service.definition.programs = [first, second]
      service.preferences.landscapeProgramPreferences[100] = .with {
        $0.videoLayerInternalIds = [20]
      }
      service.definition.videoComponents = [10, 20].map {
        WorkspaceResourceFactory.makeSolidColor(id: UInt64($0), name: "Color \($0)")
      }
      service.preferences.landscapeProgramPreferences[100, default: .init()].videoLayerHidden[10] =
        true
      let preferences = service.preferences
      let controls = VideoComponentProgramLayers(
        storeService: service, componentID: .solidColorFill(10))
      let landscape = controls.membership(for: 100, target: .landscape)
      let portrait = controls.membership(for: 100, target: .portrait)
      #expect(!landscape.wrappedValue && !portrait.wrappedValue)
      landscape.wrappedValue = true
      landscape.wrappedValue = true
      portrait.wrappedValue = true
      #expect(
        (service.preferences.landscapeProgramPreferences[100]?.videoLayerInternalIds ?? []) == [
          20, 10,
        ])
      #expect(
        (service.preferences.portraitProgramPreferences[100]?.videoLayerInternalIds ?? []) == [10])
      landscape.wrappedValue = false
      #expect(
        (service.preferences.landscapeProgramPreferences[100]?.videoLayerInternalIds ?? []) == [20])
      #expect(portrait.wrappedValue)
      #expect(
        service.preferences.landscapeProgramPreferences[100]?.videoLayerHidden
          == preferences.landscapeProgramPreferences[100]?.videoLayerHidden)
      service.isOutputActive = true
      portrait.wrappedValue = false
      #expect(portrait.wrappedValue)
      service.isOutputActive = false
      service.definition.programs.swapAt(0, 1)
      portrait.wrappedValue = false
      #expect(
        (service.preferences.portraitProgramPreferences[100]?.videoLayerInternalIds ?? []) == [10])
      let newProgram = controls.membership(for: 200, target: .portrait)
      newProgram.wrappedValue = true
      #expect(
        (service.preferences.portraitProgramPreferences[200]?.videoLayerInternalIds ?? []) == [10])
      service.definition.videoComponents.removeAll { $0.id == .solidColorFill(10) }
      newProgram.wrappedValue = false
      #expect(
        (service.preferences.portraitProgramPreferences[200]?.videoLayerInternalIds ?? []) == [10])
      #expect(throws: WorkspaceSelectionError.self) {
        try service.setVideoLayerIncluded(
          true, componentID: 999, programID: 200, target: .landscape)
      }
      #expect(throws: WorkspaceSelectionError.self) {
        try service.setVideoLayerIncluded(true, componentID: 20, programID: 999, target: .landscape)
      }
    }

    @Test("UCT-1010.2: Canvas membership and ordering remain local during output")
    func videoLayersEditorEditsBothCanvases() throws {
      _ = NSApplication.shared
      let state = WorkspaceStoreService(definition: .init(), preferences: .init())
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      program.displayName = "Main"
      state.definition.programs = [program]
      state.definition.videoComponents = [10, 20, 30].map {
        WorkspaceResourceFactory.makeSolidColor(id: UInt64($0), name: "Color \($0)")
      }
      let other = WorkspaceStoreService(definition: state.definition, preferences: .init())
      let first = makeWorkspaceTestWindow(storeService: state)
      let second = makeWorkspaceTestWindow(storeService: other)
      defer {
        first.close()
        second.close()
      }
      for target in [WorkspaceCanvasTarget.landscape, .portrait] {
        let content = first.contentPane
        for id: UInt64 in [10, 20, 30] {
          try content.storeService.setVideoLayerIncluded(
            true, componentID: id, programID: 100, target: target)
        }
        try content.storeService.commitLayerOrder([30, 10, 20], programID: 100, target: target)
        #expect(
          (state.preferences[keyPath: target.preferences][100] ?? .init())[keyPath: target.layerIDs]
            == [30, 10, 20])
        #expect(throws: WorkspaceSelectionError.self) {
          try content.storeService.commitLayerOrder([10], programID: 100, target: target)
        }
        try content.storeService.setVideoLayerIncluded(
          false, componentID: 30, programID: 100, target: target)
        var preference = try content.storeService.preferences(for: 100, target: target)
        preference.audioMasterVolumeDecibels = .with {
          $0.numerator = -8
          $0.denominator = 1
        }
        preference.videoLayerHidden[10] = true
        try content.storeService.commitPreferences(preference, programID: 100, target: target)
        #expect(state.preferences[keyPath: target.preferences][100]?.videoLayerHidden[10] == true)
        #expect(
          state.preferences[keyPath: target.preferences][100]?.audioMasterVolumeDecibels
            == Ldtx_Workspace_V4_Rational32.with {
              $0.set(num: -80, den: 10)
            })
        for value in [WorkspaceRecordingState.starting, .recording, .pausing, .stopping] {
          state.isOutputActive = value.isOutputActive
          #expect(throws: WorkspaceSelectionError.self) {
            try content.storeService.setVideoLayerIncluded(
              false, componentID: 20, programID: 100, target: target)
          }
          try content.storeService.commitLayerOrder([20, 10], programID: 100, target: target)
          try content.storeService.commitLayerOrder([10, 20], programID: 100, target: target)
        }
        state.isOutputActive = false
        try content.storeService.setVideoLayerIncluded(
          false, componentID: 20, programID: 100, target: target)
      }
      #expect(
        (state.preferences.landscapeProgramPreferences[100]?.videoLayerInternalIds ?? []) == [10])
      #expect(
        (state.preferences.portraitProgramPreferences[100]?.videoLayerInternalIds ?? []) == [10])
      #expect(
        (other.preferences.landscapeProgramPreferences[100]?.videoLayerInternalIds ?? []).isEmpty)
      #expect(
        (other.preferences.portraitProgramPreferences[100]?.videoLayerInternalIds ?? []).isEmpty)
      #expect(state.inspectorSelector == nil)
      #expect(other.inspectorSelector == nil)
      #expect(WorkspaceInspectorKind(rawValue: 1) == nil)
      #expect(WorkspaceInspectorKind.workspaceCanvas.rawValue == 2)
      #expect(WorkspaceInspectorKind.ocrVision.rawValue == 13)
    }
  }
}
