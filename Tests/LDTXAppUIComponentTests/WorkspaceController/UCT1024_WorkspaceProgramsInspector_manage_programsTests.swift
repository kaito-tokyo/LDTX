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
      let serviceEditingState = WorkspaceEditingState()
      let service = WorkspaceStoreService(definition: .init(), preferences: .init())
      service.workspaceDefinition.programs = [
        .with {
          $0.internalID = 1
          $0.displayName = "Program"
        }
      ]
      service.workspaceDefinition.audioDevices = [
        WorkspaceResourceFactory.makeAudioInput(id: 2, name: "Audio")
      ]
      service.workspaceDefinition.videoComponents = [
        WorkspaceResourceFactory.makeVFXSource(id: 3, name: "Video")
      ]
      service.workspaceDefinition.visions = [
        .with {
          $0.ocrVision = .with {
            $0.internalID = 4
            $0.displayName = "Vision"
          }
        }
      ]
      let inspector = WorkspaceProgramsInspector(
        storeService: service, editingState: serviceEditingState, appletData: WorkspaceAppletData())
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
      let service = document.storeService
      service.workspaceDefinition.programs = [
        .with {
          $0.internalID = 100
          $0.displayName = "First"
        },
        .with {
          $0.internalID = 101
          $0.displayName = "Second"
        },
      ]
      service.workspacePreferences.landscapeProgramPreferences[101] = .init()
      service.workspacePreferences.portraitProgramPreferences[101] = .init()
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("DeletedProgram.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: url)
      document.updateChangeCount(.changeCleared)
      #expect(!document.isDocumentEdited)
      let controller = WorkspaceWindowController(
        storeService: service, editingState: document.editingState,
        persistenceCoordinator: document.persistenceCoordinator,
        appletData: document.appletData, documentReference: DocumentReference(document))
      document.addWindowController(controller)
      service.isOutputActive = true
      #expect(throws: (any Error).self) { try controller.removeProgram(internalID: 101) }
      #expect(service.workspaceDefinition.programs.count == 2)
      #expect(!document.isDocumentEdited)
      service.isOutputActive = false
      try controller.selectProgram(internalID: 101)
      let editor = MasterVolumeEditor(
        storeService: service, appletData: document.appletData, peakMeter: .init(),
        reportError: { _ in }, editingState: document.editingState)
      _ = editor.view
      let field = editor.masterFields[0]
      field.stringValue = "invalid"
      field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
      let definitionBeforeDeletion = service.workspaceDefinition
      let preferencesBeforeDeletion = service.workspacePreferences
      #expect(throws: (any Error).self) { try controller.removeProgram(internalID: 101) }
      #expect(service.workspaceDefinition == definitionBeforeDeletion)
      #expect(service.workspacePreferences == preferencesBeforeDeletion)
      #expect(
        document.appletData.selectedProgram(
          in: service.workspaceDefinition, for: service.localStateURL)?.internalID == 101)
      #expect(field.dirty && field.stringValue == "invalid")
      #expect(!document.isDocumentEdited)
      field.stringValue = "-12"
      #expect(throws: (any Error).self) { try controller.removeProgram(internalID: 101) }
      try field.submit()
      try controller.removeProgram(internalID: 101)
      #expect(service.workspaceDefinition.programs.map(\.internalID) == [100])
      #expect(service.workspacePreferences.landscapeProgramPreferences[101] == nil)
      #expect(service.workspacePreferences.portraitProgramPreferences[101] == nil)
      #expect(document.isDocumentEdited)
      document.updateChangeCount(.changeCleared)
      #expect(throws: (any Error).self) { try controller.removeProgram(internalID: 101) }
      #expect(!document.isDocumentEdited)
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      let reopened = WorkspaceDocument()
      defer { reopened.close() }
      try reopened.read(from: url, ofType: "tokyo.kaito.ldtx.workspace")
      #expect(reopened.storeService.workspaceDefinition.programs.map(\.internalID) == [100])
      #expect(reopened.storeService.workspacePreferences.landscapeProgramPreferences[101] == nil)
      #expect(reopened.storeService.workspacePreferences.portraitProgramPreferences[101] == nil)
      await controller.shutdown()
      controller.window?.close()
      document.close()
    }
  }
}
