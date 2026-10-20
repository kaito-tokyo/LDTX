// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXBackgroundSegmentation
import LDTXProtos
@testable import LDTXWorkspaceAppletController
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1024: Manage Programs", .serialized)
  @MainActor
  struct UCT1024WorkspaceProgramsInspectorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("UCT-1024.1: Rename validates all resource names and preserves rejected edits")
    func renameValidatesResourceNames() throws {
      let service = WorkspaceDocument(definition: .init(), preferences: .init())
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [
          .with {
            $0.internalID = 1
            $0.displayName = "Program"
          }
        ]
      }
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.audioDevices = [
          WorkspaceResourceFactory.makeAudioInput(id: 2, name: "Audio")
        ]
      }
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          WorkspaceResourceFactory.makeVFXSource(id: 3, name: "Video")
        ]
      }
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.visions = [
          .with {
            $0.ocrVision = .with {
              $0.internalID = 4
              $0.displayName = "Vision"
            }
          }
        ]
      }
      let inspector = WorkspaceProgramsInspector(
        stateService: service, appletData: WorkspaceAppletData())
      for name in ["", "Audio", "Video", "Vision"] {
        #expect(throws: (any Error).self) { try inspector.renameProgram(internalID: 1, name: name) }
        #expect(service.workspaceDefinition.programs[0].displayName == "Program")
      }
      try inspector.renameProgram(internalID: 1, name: "  Renamed  ")
      #expect(service.workspaceDefinition.programs[0].displayName == "Renamed")
      try inspector.renameProgram(internalID: 1, name: "Renamed")
      #expect(throws: (any Error).self) {
        try inspector.renameProgram(internalID: 999, name: "Missing")
      }
      service.isOutputActive = true
      #expect(throws: (any Error).self) {
        try inspector.renameProgram(internalID: 1, name: "Blocked")
      }
      #expect(service.workspaceDefinition.programs[0].displayName == "Renamed")
    }

    @Test("UCT-1024.2: Delete removes only the requested Program and its preferences")
    func deleteUsesExistingRuntimeAndPreservesOtherPrograms() async throws {
      _ = NSApplication.shared
      let document = WorkspaceDocument()
      let service = document.stateService
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.programs = [
          .with {
            $0.internalID = 100
            $0.displayName = "First"
          },
          .with {
            $0.internalID = 101
            $0.displayName = "Second"
          },
        ]
      }
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences.landscapeProgramPreferences[101] = .init()
      }
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences.portraitProgramPreferences[101] = .init()
      }
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("DeletedProgram.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: url)
      document.captureTestBaseline()
      #expect(!document.hasTestModelChanges)
      let controller = WorkspaceAppletCoordinator(
        stateService: service,
        persistenceCoordinator: document.persistenceCoordinator,
        appletData: document.appletData, document: document)
      document.addWindowController(controller)
      service.isOutputActive = true
      #expect(throws: (any Error).self) { try controller.removeProgram(internalID: 101) }
      #expect(service.workspaceDefinition.programs.count == 2)
      #expect(!document.hasTestModelChanges)
      service.isOutputActive = false
      _ = await (try controller.selectProgram(internalID: 101)).value
      service.editWorkspace(undoManager: nil) { workspace in
        workspace.preferences.landscapeProgramPreferences[101, default: .init()]
          .audioMasterVolumeDecibels = .with { $0.set(num: -120, den: 10) }
      }
      let selectionBeforeDelete = controller.programSelectionState.value
      try controller.removeProgram(internalID: 101)
      #expect(controller.programSelectionState.value == 100)
      #expect(
        controller.windowRuntime.definition.programs.contains {
          $0.internalID == selectionBeforeDelete
        })
      #expect(service.workspaceDefinition.programs.map(\.internalID) == [100])
      #expect(service.workspacePreferences.landscapeProgramPreferences[101] == nil)
      #expect(service.workspacePreferences.portraitProgramPreferences[101] == nil)
      #expect(document.hasTestModelChanges)
      document.captureTestBaseline()
      #expect(throws: (any Error).self) { try controller.removeProgram(internalID: 101) }
      #expect(!document.hasTestModelChanges)
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      let reopened = try await loadWorkspaceDocument(at: url)
      defer { reopened.close() }
      #expect(reopened.stateService.workspaceDefinition.programs.map(\.internalID) == [100])
      #expect(reopened.stateService.workspacePreferences.landscapeProgramPreferences[101] == nil)
      #expect(reopened.stateService.workspacePreferences.portraitProgramPreferences[101] == nil)
      await controller.shutdown()
      controller.window?.close()
      document.close()
    }
  }
}
