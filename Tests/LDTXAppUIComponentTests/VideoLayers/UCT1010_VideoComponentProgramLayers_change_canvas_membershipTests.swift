// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXCorelibs
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite.Shard2 {
  @Suite("UCT-1010: change-canvas-membership", .serialized)
  @MainActor
  struct UCT1010VideoComponentProgramLayersIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }
    @Test("LUB-1048: Dynamic text can be placed in both program canvases")
    func dynamicTextCanBePlacedInBothProgramCanvases() throws {
      let data = WorkspaceAppletData()
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [.with { $0.internalID = 100 }]
      }
      try state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          try WorkspaceResourceFactory.makeDynamicText(id: 10, name: "Text")
        ]
      }
      let controls = VideoComponentProgramLayers(
        stateService: state, appletData: data, componentID: 10)
      for target in [WorkspaceCanvasTarget.landscape, .portrait] {
        let membership = controls.membership(for: 100, target: target)
        membership.wrappedValue = true
        #expect(membership.wrappedValue)
        let editor = VideoLayersEditorState(stateService: state, appletData: data, target: target)
        let row = try #require(editor.rows[10])
        #expect(row.supportsPlacement)
        #expect(row.name == "Text")
      }
    }

    @Test("LUB-1048: Active output allows reordering but rejects membership and count changes")
    func activeOutputPreservesLayerMembership() throws {
      let serviceAppletData = WorkspaceAppletData()
      let service = WorkspaceDocument(
        definition: .with {
          $0.programs = [.with { $0.internalID = 100 }]
        }, preferences: .init())
      var preferences = Ldtx_Workspace_V4_ProgramPreferences()
      preferences.videoLayerInternalIds = [10, 20]
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences.landscapeProgramPreferences[100] = preferences
      }
      service.isOutputActive = true
      preferences.videoLayerInternalIds = [20, 10]
      try VideoLayersEditorState(
        stateService: service, appletData: serviceAppletData,
        target: .landscape
      ).commitLayerOrder(
        preferences.videoLayerInternalIds, programID: 100)
      for ids: [Int64] in [[10], [10, 20, 30], [10, 20, 20]] {
        preferences.videoLayerInternalIds = ids
        #expect(throws: WorkspaceSelectionError.self) {
          try VideoLayersEditorState(
            stateService: service, appletData: serviceAppletData,
            target: .landscape
          ).commitLayerOrder(
            preferences.videoLayerInternalIds, programID: 100)
        }
        #expect(
          (service.workspacePreferences.landscapeProgramPreferences[100] ?? .init())
            .videoLayerInternalIds == [20, 10])
      }
    }

    @Test(
      "LUB-1048: UCT-1010.1: Component inspector membership uses latest program and preserves preferences"
    )
    func componentInspectorMembershipUsesLatestProgramAndPreservesPreferences() throws {
      let serviceAppletData = WorkspaceAppletData()
      let service = WorkspaceDocument(definition: .init(), preferences: .init())
      var first = Ldtx_Workspace_V4_ProgramDefinition()
      first.internalID = 100
      var second = Ldtx_Workspace_V4_ProgramDefinition()
      second.internalID = 200
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [first, second]
      }
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences.landscapeProgramPreferences[100] = .with {
          $0.videoLayerInternalIds = [20]
          $0.audioMasterVolumeDecibels = .with { $0.set(num: -8, den: 1) }
        }
      }
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [10, 20].map {
          WorkspaceResourceFactory.makeSolidColor(id: Int64($0), name: "Color \($0)")
        }
      }
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences.landscapeProgramPreferences[100, default: .init()]
          .videoLayerHidden[10] =
          true
      }
      let preferences = service.workspacePreferences
      let controls = VideoComponentProgramLayers(
        stateService: service, appletData: serviceAppletData, componentID: 10)
      let landscape = controls.membership(for: 100, target: .landscape)
      let portrait = controls.membership(for: 100, target: .portrait)
      #expect(!landscape.wrappedValue && !portrait.wrappedValue)
      landscape.wrappedValue = true
      landscape.wrappedValue = true
      portrait.wrappedValue = true
      #expect(
        (service.workspacePreferences.landscapeProgramPreferences[100]?.videoLayerInternalIds ?? [])
          == [
            20, 10,
          ])
      #expect(
        (service.workspacePreferences.portraitProgramPreferences[100]?.videoLayerInternalIds ?? [])
          == [10])
      landscape.wrappedValue = false
      #expect(
        (service.workspacePreferences.landscapeProgramPreferences[100]?.videoLayerInternalIds ?? [])
          == [20])
      #expect(portrait.wrappedValue)
      #expect(
        service.workspacePreferences.landscapeProgramPreferences[100]?.videoLayerHidden
          == preferences.landscapeProgramPreferences[100]?.videoLayerHidden)
      #expect(
        service.workspacePreferences.landscapeProgramPreferences[100]?.audioMasterVolumeDecibels
          == preferences.landscapeProgramPreferences[100]?.audioMasterVolumeDecibels)
      service.isOutputActive = true
      portrait.wrappedValue = false
      #expect(portrait.wrappedValue)
      service.isOutputActive = false
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs.swapAt(0, 1)
      }
      portrait.wrappedValue = false
      #expect(
        (service.workspacePreferences.portraitProgramPreferences[100]?.videoLayerInternalIds ?? [])
          == [10])
      let newProgram = controls.membership(for: 200, target: .portrait)
      newProgram.wrappedValue = true
      #expect(
        (service.workspacePreferences.portraitProgramPreferences[200]?.videoLayerInternalIds ?? [])
          == [10])
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents.removeAll { $0.internalID == 10 }
      }
      newProgram.wrappedValue = false
      #expect(
        (service.workspacePreferences.portraitProgramPreferences[200]?.videoLayerInternalIds ?? [])
          == [10])
      #expect(throws: WorkspaceSelectionError.self) {
        try VideoComponentProgramLayers(
          stateService: service, appletData: serviceAppletData, componentID: 999
        ).setIncluded(
          true, programID: 200, target: .landscape)
      }
      #expect(throws: WorkspaceSelectionError.self) {
        try VideoComponentProgramLayers(
          stateService: service, appletData: serviceAppletData, componentID: 20
        ).setIncluded(
          true, programID: 999, target: .landscape)
      }
    }

    @Test("LUB-1048: UCT-1010.2: Canvas membership and ordering remain local during output")
    func videoLayersEditorEditsBothCanvases() throws {
      _ = NSApplication.shared
      let state = WorkspaceDocument(definition: .init(), preferences: .init())
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      program.displayName = "Main"
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [program]
      }
      state.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [10, 20, 30].map {
          WorkspaceResourceFactory.makeSolidColor(id: Int64($0), name: "Color \($0)")
        }
      }
      let other = WorkspaceDocument(definition: state.workspaceDefinition, preferences: .init())
      let first = makeWorkspaceTestWindow(stateService: state)
      let second = makeWorkspaceTestWindow(stateService: other)
      defer {
        first.close()
        second.close()
      }
      for target in [WorkspaceCanvasTarget.landscape, .portrait] {
        let content = first.contentPane
        for id: Int64 in [10, 20, 30] {
          try VideoComponentProgramLayers(
            stateService: content.stateService, appletData: content.appletData, componentID: id
          )
          .setIncluded(true, programID: 100, target: target)
        }
        try VideoLayersEditorState(
          stateService: content.stateService, appletData: content.appletData, target: target
        ).commitLayerOrder(
          [30, 10, 20], programID: 100)
        #expect(
          (state.workspacePreferences[keyPath: target.preferences][100] ?? .init())[
            keyPath: target.layerIDs]
            == [30, 10, 20])
        #expect(throws: WorkspaceSelectionError.self) {
          try VideoLayersEditorState(
            stateService: content.stateService, appletData: content.appletData, target: target
          )
          .commitLayerOrder([10], programID: 100)
        }
        try VideoComponentProgramLayers(
          stateService: content.stateService, appletData: content.appletData, componentID: 30
        )
        .setIncluded(false, programID: 100, target: target)
        var preference =
          (content.stateService.workspacePreferences[keyPath: target.preferences][100] ?? .init())
        preference.audioMasterVolumeDecibels = .with {
          $0.set(num: -80, den: 10)
        }
        preference.videoLayerHidden[10] = true
        content.stateService.editWorkspace(undoManager: nil) { workspace in
          workspace.preferences[keyPath: target.preferences][100] = preference
        }
        #expect(
          state.workspacePreferences[keyPath: target.preferences][100]?.videoLayerHidden[10] == true
        )
        #expect(
          state.workspacePreferences[keyPath: target.preferences][100]?.audioMasterVolumeDecibels
            == Ldtx_Workspace_V4_Rational32.with {
              $0.set(num: -80, den: 10)
            })
        for value in [WorkspaceRecordingState.starting, .recording, .pausing, .stopping] {
          state.isOutputActive = value.isOutputActive
          #expect(throws: WorkspaceSelectionError.self) {
            try VideoComponentProgramLayers(
              stateService: content.stateService, appletData: content.appletData, componentID: 20
            )
            .setIncluded(false, programID: 100, target: target)
          }
          try VideoLayersEditorState(
            stateService: content.stateService, appletData: content.appletData, target: target
          )
          .commitLayerOrder([20, 10], programID: 100)
          try VideoLayersEditorState(
            stateService: content.stateService, appletData: content.appletData, target: target
          )
          .commitLayerOrder([10, 20], programID: 100)
        }
        state.isOutputActive = false
        try VideoComponentProgramLayers(
          stateService: content.stateService, appletData: content.appletData, componentID: 20
        )
        .setIncluded(false, programID: 100, target: target)
      }
      #expect(
        (state.workspacePreferences.landscapeProgramPreferences[100]?.videoLayerInternalIds ?? [])
          == [10])
      #expect(
        (state.workspacePreferences.portraitProgramPreferences[100]?.videoLayerInternalIds ?? [])
          == [10])
      #expect(
        (other.workspacePreferences.landscapeProgramPreferences[100]?.videoLayerInternalIds ?? [])
          .isEmpty)
      #expect(
        (other.workspacePreferences.portraitProgramPreferences[100]?.videoLayerInternalIds ?? [])
          .isEmpty)
      #expect(state.inspectorSelector == nil)
      #expect(other.inspectorSelector == nil)
      #expect(WorkspaceInspectorKind(rawValue: 1) == nil)
      #expect(WorkspaceInspectorKind.workspaceCanvas.rawValue == 2)
      #expect(WorkspaceInspectorKind.ocrVision.rawValue == 13)
    }
  }
}
