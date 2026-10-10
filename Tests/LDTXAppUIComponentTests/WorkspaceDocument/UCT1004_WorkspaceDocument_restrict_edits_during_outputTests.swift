// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXAppletSupport
import LDTXProgramRuntime
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import SwiftProtobuf
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1004: restrict-edits-during-output", .serialized)
  @MainActor
  struct UCT1004WorkspaceDocumentIntegrationTestSuite {
    private static var controller: NSDocumentController {
      UIComponentTestEnvironment.documentController
    }
    init() { _ = Self.controller }

    @Test("UCT-1004.1: Output permits only layer permutations and saves the latest order")
    func outputAllowsOnlyLayerPermutationsAndPersistsLatestOrder() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      defer {
        document.storeService.isOutputActive = false
        document.close()
      }
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 101
      program.displayName = "Main"
      document.storeService.workspaceDefinition.programs = [program]
      document.storeService.workspaceDefinition.videoComponents = [1, 2, 3].map { id in
        var device = Ldtx_Workspace_V4_VfxSourceComponent()
        device.internalID = Int64(id)
        device.displayName = "Camera \(id)"
        var wrapper = Ldtx_Workspace_V4_VideoComponentWrapper()
        wrapper.vfxSource = device
        return wrapper
      }
      document.storeService.workspacePreferences.landscapeProgramPreferences[101] = .with {
        $0.videoLayerInternalIds = [1, 2, 3]
      }
      document.storeService.workspacePreferences.portraitProgramPreferences[101] = .with {
        $0.videoLayerInternalIds = [3, 2, 1]
      }
      let url = root.appendingPathComponent("Workspace.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: url)
      document.storeService.isOutputActive = true
      let definition = document.storeService.workspaceDefinition
      let outputSettings = document.storeService.workspaceOutputSettings
      try VideoLayersEditor(
        storeService: document.storeService, appletData: document.appletData,
        editingState: document.editingState, target: .landscape
      )
      .commitLayerOrder([3, 1, 2], programID: 101)
      try VideoLayersEditor(
        storeService: document.storeService, appletData: document.appletData,
        editingState: document.editingState, target: .portrait
      )
      .commitLayerOrder([1, 3, 2], programID: 101)
      #expect(document.isDocumentEdited)
      let reordered = document.storeService.workspacePreferences
      for rejected: [Int64] in [[3, 1], [3, 1, 2, 4], [3, 1, 1]] {
        #expect(throws: WorkspaceSelectionError.self) {
          try VideoLayersEditor(
            storeService: document.storeService, appletData: document.appletData,
            editingState: document.editingState, target: .landscape
          )
          .commitLayerOrder(rejected, programID: 101)
        }
        #expect(document.storeService.workspacePreferences == reordered)
      }
      try VideoLayersEditor(
        storeService: document.storeService, appletData: document.appletData,
        editingState: document.editingState, target: .landscape
      )
      .commitLayerOrder([2, 3, 1], programID: 101)
      let latest = document.storeService.workspacePreferences
      try await saveWorkspaceDocument(document, to: url, operation: .saveOperation)
      let persisted = try WorkspaceBundleReaderV4(at: url).read()
      #expect(persisted.definition == definition)
      #expect(persisted.preferences == latest)
      #expect(persisted.outputSettings == outputSettings)
      document.storeService.isOutputActive = false
      let reopened = WorkspaceDocument()
      defer { reopened.close() }
      try reopened.read(from: url, ofType: "tokyo.kaito.ldtx.workspace")
      #expect(reopened.storeService.workspaceDefinition == definition)
      #expect(reopened.storeService.workspacePreferences == latest)
      #expect(reopened.storeService.workspaceOutputSettings == outputSettings)
    }

    @Test("UCT-1004.2: Starting output does not save pending edits")
    func startingOutputDoesNotSavePendingModelEdits() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("Output.ldtxworkspace")
      let document = WorkspaceDocument()
      defer { document.close() }
      try await saveWorkspaceDocument(document, to: url)
      let definition = try Data(contentsOf: url.appendingPathComponent("definition.pb"))
      let preferences = try Data(contentsOf: url.appendingPathComponent("preferences.pb"))
      document.makeWindowControllers()
      let controller = try #require(document.windowControllers.first as? WorkspaceWindowController)
      document.storeService.workspaceDefinition.displayName = "Pending"
      // No Program/output is enabled, so this exercises the entry without media I/O.
      try await controller.startOutput()
      #expect(document.isDocumentEdited)
      #expect(document.storeService.workspaceDefinition.displayName == "Pending")
      #expect(try Data(contentsOf: url.appendingPathComponent("definition.pb")) == definition)
      #expect(try Data(contentsOf: url.appendingPathComponent("preferences.pb")) == preferences)
      await document.shutdown()
    }

    @Test("UCT-1004.3: Workspace definition assignments remain transparent during output")
    func definitionAssignmentsRemainTransparent() {
      let document = WorkspaceDocument()
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 101
      program.displayName = "Main"
      document.storeService.workspaceDefinition.programs = [program]
      document.updateChangeCount(.changeCleared)
      document.storeService.isOutputActive = true
      document.storeService.workspaceDefinition.displayName = "Updated"
      #expect(document.storeService.workspaceDefinition.displayName == "Updated")
      let replacement = Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
        $0.displayName = "Replacement"
      }
      document.storeService.workspaceDefinition = replacement
      #expect(document.storeService.workspaceDefinition == replacement)
      #expect(document.isDocumentEdited)
      document.storeService.workspacePreferences.landscapeProgramPreferences[101, default: .init()]
        .audioMasterVolumeDecibels = .with {
          $0.num = -6
          $0.den = 1
        }
      #expect(document.isDocumentEdited)
    }

    @Test("UCT-1004.4: Output disables Save As and Revert")
    func outputDisablesSaveAsAndRevert() {
      let document = WorkspaceDocument()
      document.storeService.isOutputActive = true
      let saveAs = NSMenuItem(
        title: "Save As", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "")
      let revert = NSMenuItem(
        title: "Revert", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
      #expect(!document.validateUserInterfaceItem(saveAs))
      #expect(!document.validateUserInterfaceItem(revert))
    }
  }
}
