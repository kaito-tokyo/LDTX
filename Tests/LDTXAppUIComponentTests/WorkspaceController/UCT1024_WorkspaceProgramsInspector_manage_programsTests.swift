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
      let service = WorkspaceStoreService(definition: .init(), preferences: .init())
      service.definition.programs = [
        .with {
          $0.internalID = 1
          $0.displayName = "Program"
        }
      ]
      service.definition.audioDevices = [
        WorkspaceResourceFactory.makeAudioInput(id: 2, name: "Audio")
      ]
      service.definition.videoComponents = [
        WorkspaceResourceFactory.makeVFXSource(id: 3, name: "Video")
      ]
      service.definition.visions = [
        .with {
          $0.ocrVision = .with {
            $0.internalID = 4
            $0.displayName = "Vision"
          }
        }
      ]
      for name in ["", "Audio", "Video", "Vision"] {
        #expect(throws: (any Error).self) { try service.renameProgram(internalID: 1, name: name) }
        #expect(service.definition.programs[0].displayName == "Program")
      }
      try service.renameProgram(internalID: 1, name: "  Renamed  ")
      #expect(service.definition.programs[0].displayName == "Renamed")
      try service.renameProgram(internalID: 1, name: "Renamed")
      #expect(throws: (any Error).self) {
        try service.renameProgram(internalID: 999, name: "Missing")
      }
      service.isOutputActive = true
      #expect(throws: (any Error).self) {
        try service.renameProgram(internalID: 1, name: "Blocked")
      }
      #expect(service.definition.programs[0].displayName == "Renamed")
    }

    @Test("UCT-1024.2: Delete removes only the requested Program and its preferences")
    func deleteUsesExistingRuntimeAndPreservesOtherPrograms() async throws {
      _ = NSApplication.shared
      let document = WorkspaceDocument()
      let service = document.storeService
      service.definition.programs = [
        .with {
          $0.internalID = 100
          $0.displayName = "First"
        },
        .with {
          $0.internalID = 101
          $0.displayName = "Second"
        },
      ]
      service.preferences.landscapeProgramPreferences[101] = .init()
      service.preferences.portraitProgramPreferences[101] = .init()
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("DeletedProgram.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: url)
      document.updateChangeCount(.changeCleared)
      #expect(!document.isDocumentEdited)
      let controller = WorkspaceWindowController(
        storeService: service, persistenceCoordinator: document.persistenceCoordinator,
        appletData: WorkspaceAppletData(), documentReference: DocumentReference(document))
      document.addWindowController(controller)
      service.isOutputActive = true
      #expect(throws: (any Error).self) { try service.removeProgram(internalID: 101) }
      #expect(service.definition.programs.count == 2)
      #expect(!document.isDocumentEdited)
      service.isOutputActive = false
      try service.selectProgram(internalID: 101)
      let editor = MasterVolumeEditor(storeService: service)
      _ = editor.view
      let field = editor.masterFields[0]
      field.stringValue = "invalid"
      field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
      let definitionBeforeDeletion = service.definition
      let preferencesBeforeDeletion = service.preferences
      #expect(throws: (any Error).self) { try service.removeProgram(internalID: 101) }
      #expect(service.definition == definitionBeforeDeletion)
      #expect(service.preferences == preferencesBeforeDeletion)
      #expect(service.selectedProgram?.internalID == 101)
      #expect(field.dirty && field.stringValue == "invalid")
      #expect(!document.isDocumentEdited)
      field.stringValue = "-12"
      try service.removeProgram(internalID: 101)
      #expect(service.definition.programs.map(\.internalID) == [100])
      #expect(service.preferences.landscapeProgramPreferences[101] == nil)
      #expect(service.preferences.portraitProgramPreferences[101] == nil)
      #expect(document.isDocumentEdited)
      document.updateChangeCount(.changeCleared)
      #expect(throws: (any Error).self) { try service.removeProgram(internalID: 101) }
      #expect(!document.isDocumentEdited)
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      let reopened = WorkspaceDocument()
      defer { reopened.close() }
      try reopened.read(from: url, ofType: "tokyo.kaito.ldtx.workspace")
      #expect(reopened.storeService.definition.programs.map(\.internalID) == [100])
      #expect(reopened.storeService.preferences.landscapeProgramPreferences[101] == nil)
      #expect(reopened.storeService.preferences.portraitProgramPreferences[101] == nil)
      await controller.shutdown()
      controller.window?.close()
      document.close()
    }
  }
}
